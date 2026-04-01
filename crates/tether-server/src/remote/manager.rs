use std::sync::Arc;
use std::time::Duration;
use tokio::net::TcpStream;
use tokio::time::timeout;

use dashmap::DashMap;
use serde::Serialize;

use crate::ssh_config::{parse_ssh_config, SshHost};
use super::client::SshClient;
use super::deploy::ensure_deployed;
use super::tunnel::Tunnel;

// ── Public types ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum RemoteStatus {
    Unreachable,
    Connecting,
    Deploying,
    Ready,
    Failed(String),
}

#[derive(Debug, Clone, Serialize)]
pub struct RemoteHostStatus {
    pub host: String,
    pub status: RemoteStatus,
    /// Local port forwarded to remote:7680, present when status == Ready
    pub tunnel_port: Option<u16>,
}

// ── Internal state ────────────────────────────────────────────────────────────

struct RemoteHostState {
    ssh_host: SshHost,
    status: RemoteStatus,
    client: Option<SshClient>,
    tunnel: Option<Tunnel>,
    /// ID of the default group created on the remote tether-server.
    remote_group_id: Option<String>,
}

// ── RemoteManager ─────────────────────────────────────────────────────────────

#[derive(Clone)]
pub struct RemoteManager {
    hosts: Arc<DashMap<String, RemoteHostState>>,
}

impl RemoteManager {
    pub fn new() -> Self {
        Self {
            hosts: Arc::new(DashMap::new()),
        }
    }

    /// Return the remote default group ID for `host_alias` if it is Ready.
    pub fn get_remote_group_id(&self, host_alias: &str) -> Option<String> {
        self.hosts.get(host_alias).and_then(|s| {
            if matches!(s.status, RemoteStatus::Ready) {
                s.remote_group_id.clone()
            } else {
                None
            }
        })
    }

    /// Return the local tunnel port for `host_alias` if it is Ready.
    pub fn get_tunnel_port(&self, host_alias: &str) -> Option<u16> {
        self.hosts.get(host_alias).and_then(|s| {
            if matches!(s.status, RemoteStatus::Ready) {
                s.tunnel.as_ref().map(|t| t.local_port)
            } else {
                None
            }
        })
    }

    /// Return a snapshot of all discovered hosts and their statuses.
    pub fn list_statuses(&self) -> Vec<RemoteHostStatus> {
        self.hosts
            .iter()
            .map(|entry| RemoteHostStatus {
                host: entry.key().clone(),
                status: entry.status.clone(),
                tunnel_port: entry
                    .tunnel
                    .as_ref()
                    .map(|t| t.local_port)
                    .filter(|_| entry.status == RemoteStatus::Ready),
            })
            .collect()
    }

    fn set_status(&self, host_alias: &str, status: RemoteStatus) {
        if let Some(mut entry) = self.hosts.get_mut(host_alias) {
            entry.status = status;
        }
    }
}

impl RemoteManager {
    /// Inject a Ready host state pointing at an already-listening local port.
    /// Only for use in tests — bypasses real SSH and deployment.
    pub fn inject_ready_for_testing(&self, host_alias: &str, tunnel_port: u16, remote_group_id: &str) {
        self.hosts.insert(
            host_alias.to_string(),
            RemoteHostState {
                ssh_host: SshHost {
                    host: host_alias.to_string(),
                    hostname: None,
                    user: None,
                    port: None,
                    identity_file: None,
                },
                status: RemoteStatus::Ready,
                client: None,
                tunnel: Some(Tunnel::new_for_testing(tunnel_port)),
                remote_group_id: Some(remote_group_id.to_string()),
            },
        );
    }

    /// Immediately mark the host as Unreachable and drop its tunnel/client state.
    /// Called proactively when any handler detects that the tunnel port is dead,
    /// so the scanner will trigger a reconnect on its next cycle.
    pub fn clear_dead_tunnel(&self, host_alias: &str) {
        if let Some(mut entry) = self.hosts.get_mut(host_alias) {
            entry.status = RemoteStatus::Unreachable;
            entry.tunnel = None;
            entry.client = None;
            entry.remote_group_id = None;
        }
    }
}

// ── Background scanner ────────────────────────────────────────────────────────

async fn is_port_alive(port: u16) -> bool {
    tokio::net::TcpStream::connect(("127.0.0.1", port)).await.is_ok()
}

/// Background task: scan `~/.ssh/config` on startup then every 60 s.
/// For each reachable host that is not already Ready, connect + deploy + tunnel.
pub async fn run_scanner(manager: RemoteManager) {
    scan_and_deploy(&manager).await;

    let mut interval = tokio::time::interval(Duration::from_secs(60));
    interval.tick().await; // discard first immediate tick
    loop {
        interval.tick().await;
        scan_and_deploy(&manager).await;
    }
}

async fn scan_and_deploy(manager: &RemoteManager) {
    let hosts = parse_ssh_config("~/.ssh/config");
    if hosts.is_empty() {
        return;
    }

    // Ensure all hosts from config exist in the map
    for host in &hosts {
        manager.hosts.entry(host.host.clone()).or_insert_with(|| RemoteHostState {
            ssh_host: host.clone(),
            status: RemoteStatus::Unreachable,
            client: None,
            tunnel: None,
            remote_group_id: None,
        });
    }

    // Check reachability and trigger connect for hosts that aren't Ready
    let mut tasks = Vec::new();
    for host in hosts {
        let manager = manager.clone();
        let host_clone = host.clone();
        tasks.push(tokio::spawn(async move {
            let alias = &host_clone.host;

            // Skip if already Ready and tunnel port is still reachable
            if let Some(entry) = manager.hosts.get(alias) {
                if entry.status == RemoteStatus::Ready {
                    if let Some(t) = entry.tunnel.as_ref() {
                        if is_port_alive(t.local_port).await {
                            return;
                        }
                        tracing::info!(
                            "Tunnel for {} is dead (port {} unreachable), reconnecting...",
                            alias, t.local_port
                        );
                    }
                }
            }

            // TCP reachability check (same pattern as api/ssh.rs)
            let target = host_clone.hostname.as_deref().unwrap_or(&host_clone.host);
            let port = host_clone.port.unwrap_or(22);
            let addr = format!("{}:{}", target, port);
            let reachable = timeout(Duration::from_secs(2), TcpStream::connect(&addr))
                .await
                .map(|r| r.is_ok())
                .unwrap_or(false);

            if !reachable {
                manager.set_status(alias, RemoteStatus::Unreachable);
                return;
            }

            manager.set_status(alias, RemoteStatus::Connecting);
            tracing::info!("Connecting to remote SSH host: {}", alias);

            match connect_and_deploy(&host_clone).await {
                Ok((client, tunnel, remote_group_id)) => {
                    tracing::info!(
                        "Remote host {} is Ready (tunnel port {}, group {})",
                        alias, tunnel.local_port, remote_group_id
                    );
                    if let Some(mut entry) = manager.hosts.get_mut(alias) {
                        entry.status = RemoteStatus::Ready;
                        entry.client = Some(client);
                        entry.tunnel = Some(tunnel);
                        entry.remote_group_id = Some(remote_group_id);
                    }
                }
                Err(e) => {
                    tracing::warn!("Failed to connect/deploy to {}: {}", alias, e);
                    manager.set_status(alias, RemoteStatus::Failed(e.to_string()));
                }
            }
        }));
    }

    for task in tasks {
        let _ = task.await;
    }
}

async fn connect_and_deploy(host: &SshHost) -> anyhow::Result<(SshClient, Tunnel, String)> {
    let client = SshClient::connect(host).await?;
    ensure_deployed(&client).await?;
    let tunnel = Tunnel::start(&client.host_alias, 7680).await?;
    let remote_group_id = ensure_remote_default_group(tunnel.local_port).await?;
    Ok((client, tunnel, remote_group_id))
}

/// Ensure a "tether-default" group exists on the remote server and return its ID.
async fn ensure_remote_default_group(tunnel_port: u16) -> anyhow::Result<String> {
    let base = format!("http://127.0.0.1:{}", tunnel_port);
    let client = reqwest::Client::new();

    // Check if a group named "tether-default" already exists
    let groups: Vec<serde_json::Value> = client
        .get(format!("{}/api/groups", base))
        .send()
        .await?
        .json()
        .await?;

    if let Some(g) = groups.iter().find(|g| g["name"] == "tether-default") {
        if let Some(id) = g["id"].as_str() {
            return Ok(id.to_string());
        }
    }

    // Create it
    let created: serde_json::Value = client
        .post(format!("{}/api/groups", base))
        .json(&serde_json::json!({"name": "tether-default"}))
        .send()
        .await?
        .json()
        .await?;

    created["id"]
        .as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| anyhow::anyhow!("Remote group creation returned no id"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_host(alias: &str) -> SshHost {
        SshHost {
            host: alias.to_string(),
            hostname: None,
            user: None,
            port: None,
            identity_file: None,
        }
    }

    #[test]
    fn new_manager_is_empty() {
        let mgr = RemoteManager::new();
        assert!(mgr.list_statuses().is_empty());
    }

    #[test]
    fn get_tunnel_port_unknown_host_returns_none() {
        let mgr = RemoteManager::new();
        assert!(mgr.get_tunnel_port("nope").is_none());
    }

    #[test]
    fn get_tunnel_port_non_ready_host_returns_none() {
        let mgr = RemoteManager::new();
        mgr.hosts.insert(
            "myhost".to_string(),
            RemoteHostState {
                ssh_host: make_host("myhost"),
                status: RemoteStatus::Connecting,
                client: None,
                tunnel: None,
            remote_group_id: None,
            },
        );
        assert!(mgr.get_tunnel_port("myhost").is_none());
    }

    #[test]
    fn get_tunnel_port_ready_without_tunnel_returns_none() {
        // Ready status but no tunnel object (shouldn't happen in practice, but defensive)
        let mgr = RemoteManager::new();
        mgr.hosts.insert(
            "myhost".to_string(),
            RemoteHostState {
                ssh_host: make_host("myhost"),
                status: RemoteStatus::Ready,
                client: None,
                tunnel: None,
            remote_group_id: None,
            },
        );
        assert!(mgr.get_tunnel_port("myhost").is_none());
    }

    #[test]
    fn set_status_updates_existing_entry() {
        let mgr = RemoteManager::new();
        mgr.hosts.insert(
            "h".to_string(),
            RemoteHostState {
                ssh_host: make_host("h"),
                status: RemoteStatus::Unreachable,
                client: None,
                tunnel: None,
            remote_group_id: None,
            },
        );
        mgr.set_status("h", RemoteStatus::Deploying);
        let statuses = mgr.list_statuses();
        assert_eq!(statuses.len(), 1);
        assert!(matches!(statuses[0].status, RemoteStatus::Deploying));
    }

    #[test]
    fn set_status_noop_for_unknown_host() {
        let mgr = RemoteManager::new();
        // Should not panic
        mgr.set_status("ghost", RemoteStatus::Ready);
        assert!(mgr.list_statuses().is_empty());
    }

    #[test]
    fn list_statuses_reflects_all_hosts() {
        let mgr = RemoteManager::new();
        for alias in &["a", "b", "c"] {
            mgr.hosts.insert(
                alias.to_string(),
                RemoteHostState {
                    ssh_host: make_host(alias),
                    status: RemoteStatus::Unreachable,
                    client: None,
                    tunnel: None,
            remote_group_id: None,
                },
            );
        }
        assert_eq!(mgr.list_statuses().len(), 3);
    }

    #[test]
    fn failed_status_carries_message() {
        let mgr = RemoteManager::new();
        mgr.hosts.insert(
            "bad".to_string(),
            RemoteHostState {
                ssh_host: make_host("bad"),
                status: RemoteStatus::Failed("connection refused".to_string()),
                client: None,
                tunnel: None,
            remote_group_id: None,
            },
        );
        let s = mgr.list_statuses();
        assert!(matches!(&s[0].status, RemoteStatus::Failed(msg) if msg == "connection refused"));
    }

    #[tokio::test]
    async fn clear_dead_tunnel_marks_host_unreachable_and_clears_tunnel() {
        let mgr = RemoteManager::new();
        // Start a real listener so new_for_testing can reference a valid port
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener); // port is now dead

        mgr.inject_ready_for_testing("myhost", port, "grp-1");
        // Still reads as Ready + returns the port
        assert_eq!(mgr.get_tunnel_port("myhost"), Some(port));

        mgr.clear_dead_tunnel("myhost");

        // After clearing: get_tunnel_port returns None (host is no longer Ready)
        assert_eq!(mgr.get_tunnel_port("myhost"), None, "port should be unreachable after clear");
        let statuses = mgr.list_statuses();
        assert!(
            matches!(statuses[0].status, RemoteStatus::Unreachable),
            "status should be Unreachable"
        );

        // Simulating scanner reconnect: inject a new live tunnel
        let new_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let new_port = new_listener.local_addr().unwrap().port();
        mgr.inject_ready_for_testing("myhost", new_port, "grp-2");
        assert_eq!(mgr.get_tunnel_port("myhost"), Some(new_port));
        drop(new_listener);
    }

    #[tokio::test]
    async fn is_port_alive_returns_true_for_bound_port() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        assert!(is_port_alive(port).await);
        drop(listener);
    }

    #[tokio::test]
    async fn is_port_alive_returns_false_for_closed_port() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        assert!(!is_port_alive(port).await);
    }
}
