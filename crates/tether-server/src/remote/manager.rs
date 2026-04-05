use std::sync::Arc;
use std::time::Duration;

use dashmap::DashMap;
use serde::Serialize;
use tokio::net::TcpStream;
use tokio::sync::broadcast;
use tokio::time::timeout;

use super::client::SshClient;
use super::deploy::{
    ensure_deployed, ensure_remote_ghostty_terminfo, ensure_started_without_restart,
    remote_binary_version,
};
use super::tunnel::Tunnel;
use crate::ssh_config::{parse_ssh_config, SshHost};

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum RemoteStatus {
    Unreachable,
    Connecting,
    Ready,
    UpgradeRequired,
    Failed(String),
}

#[derive(Debug, Clone, Serialize)]
pub struct RemoteHostStatus {
    pub host: String,
    pub status: RemoteStatus,
    pub tunnel_port: Option<u16>,
}

struct RemoteHostState {
    ssh_host: SshHost,
    status: RemoteStatus,
    client: Option<SshClient>,
    tunnel: Option<Tunnel>,
}

#[derive(Clone)]
pub struct RemoteManager {
    hosts: Arc<DashMap<String, RemoteHostState>>,
    allow_deploy: bool,
    /// Fires `(host_alias, tunnel_port)` whenever a host becomes Ready.
    pub ready_tx: broadcast::Sender<(String, u16)>,
}

enum ConnectError {
    UpgradeRequired,
    Other(anyhow::Error),
}

impl From<anyhow::Error> for ConnectError {
    fn from(value: anyhow::Error) -> Self {
        Self::Other(value)
    }
}

impl RemoteManager {
    #[allow(dead_code)]
    pub fn new() -> Self {
        Self::new_with_deploy(false)
    }

    pub fn new_with_deploy(allow_deploy: bool) -> Self {
        let (ready_tx, _) = broadcast::channel(16);
        Self {
            hosts: Arc::new(DashMap::new()),
            allow_deploy,
            ready_tx,
        }
    }

    pub fn get_tunnel_port(&self, host_alias: &str) -> Option<u16> {
        self.hosts.get(host_alias).and_then(|entry| {
            if matches!(entry.status, RemoteStatus::Ready) {
                entry.tunnel.as_ref().map(|tunnel| tunnel.local_port)
            } else {
                None
            }
        })
    }

    pub fn list_statuses(&self) -> Vec<RemoteHostStatus> {
        self.hosts
            .iter()
            .map(|entry| RemoteHostStatus {
                host: entry.key().clone(),
                status: entry.status.clone(),
                tunnel_port: entry
                    .tunnel
                    .as_ref()
                    .map(|tunnel| tunnel.local_port)
                    .filter(|_| entry.status == RemoteStatus::Ready),
            })
            .collect()
    }

    pub fn list_ready_hosts(&self) -> Vec<(String, u16)> {
        self.hosts
            .iter()
            .filter_map(|entry| {
                if entry.status == RemoteStatus::Ready {
                    entry
                        .tunnel
                        .as_ref()
                        .map(|tunnel| (entry.key().clone(), tunnel.local_port))
                } else {
                    None
                }
            })
            .collect()
    }

    fn set_status(&self, host_alias: &str, status: RemoteStatus) {
        if let Some(mut entry) = self.hosts.get_mut(host_alias) {
            entry.status = status;
        }
    }

    #[allow(dead_code)]
    pub fn inject_ready_for_testing(&self, host_alias: &str, tunnel_port: u16) {
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
            },
        );
    }

    pub fn clear_dead_tunnel(&self, host_alias: &str) {
        if let Some(mut entry) = self.hosts.get_mut(host_alias) {
            entry.status = RemoteStatus::Unreachable;
            entry.tunnel = None;
            entry.client = None;
        }
    }

    pub fn trigger_connect_if_needed(&self, host_alias: &str) {
        if !self.hosts.contains_key(host_alias) {
            let hosts = parse_ssh_config("~/.ssh/config");
            if let Some(host) = hosts.into_iter().find(|host| host.host == host_alias) {
                self.hosts
                    .entry(host_alias.to_string())
                    .or_insert_with(|| RemoteHostState {
                        ssh_host: host,
                        status: RemoteStatus::Unreachable,
                        client: None,
                        tunnel: None,
                    });
            } else {
                return;
            }
        }

        let ssh_host = match self.hosts.get_mut(host_alias) {
            None => return,
            Some(mut entry) => {
                if matches!(entry.status, RemoteStatus::Connecting | RemoteStatus::Ready) {
                    return;
                }
                entry.status = RemoteStatus::Connecting;
                entry.ssh_host.clone()
            }
        };

        let manager = self.clone();
        let alias = host_alias.to_string();
        let manager_recovery = manager.clone();
        let alias_recovery = alias.clone();

        let handle = tokio::spawn(async move {
            if !is_host_reachable(&ssh_host).await {
                manager.set_status(&alias, RemoteStatus::Unreachable);
                return;
            }

            match connect_remote(&ssh_host, manager.allow_deploy).await {
                Ok((client, tunnel)) => {
                    let tunnel_port = tunnel.local_port;
                    if let Some(mut entry) = manager.hosts.get_mut(&alias) {
                        entry.status = RemoteStatus::Ready;
                        entry.client = Some(client);
                        entry.tunnel = Some(tunnel);
                    }
                    let _ = manager.ready_tx.send((alias, tunnel_port));
                }
                Err(ConnectError::UpgradeRequired) => {
                    manager.set_status(&alias, RemoteStatus::UpgradeRequired);
                }
                Err(ConnectError::Other(error)) => {
                    tracing::warn!("On-demand connect to {} failed: {}", alias, error);
                    manager.set_status(&alias, RemoteStatus::Failed(error.to_string()));
                }
            }
        });

        tokio::spawn(async move {
            if handle.await.is_err() {
                tracing::warn!(
                    "On-demand connect task for {} panicked; resetting to Unreachable",
                    alias_recovery
                );
                manager_recovery.set_status(&alias_recovery, RemoteStatus::Unreachable);
            }
        });
    }
}

async fn is_port_alive(port: u16) -> bool {
    tokio::net::TcpStream::connect(("127.0.0.1", port))
        .await
        .is_ok()
}

async fn is_host_reachable(host: &SshHost) -> bool {
    let target = host.hostname.as_deref().unwrap_or(&host.host);
    let port = host.port.unwrap_or(22);
    let addr = format!("{target}:{port}");
    timeout(Duration::from_secs(2), TcpStream::connect(&addr))
        .await
        .map(|result| result.is_ok())
        .unwrap_or(false)
}

#[derive(serde::Deserialize)]
struct RemoteInfoResponse {
    version: String,
}

#[derive(Debug, PartialEq, Eq)]
enum RemoteProbe {
    ReadyCurrentVersion,
    ReadyStaleVersion,
    Unreachable,
}

async fn probe_remote_server(tunnel_port: u16) -> RemoteProbe {
    let Ok(response) = reqwest::Client::new()
        .get(format!("http://127.0.0.1:{tunnel_port}/api/info"))
        .send()
        .await
    else {
        return RemoteProbe::Unreachable;
    };

    let Ok(response) = response.error_for_status() else {
        return RemoteProbe::Unreachable;
    };

    let Ok(info) = response.json::<RemoteInfoResponse>().await else {
        return RemoteProbe::Unreachable;
    };

    if info.version == env!("CARGO_PKG_VERSION") {
        RemoteProbe::ReadyCurrentVersion
    } else {
        RemoteProbe::ReadyStaleVersion
    }
}

async fn connect_remote(
    host: &SshHost,
    allow_deploy: bool,
) -> Result<(SshClient, Tunnel), ConnectError> {
    let client = SshClient::connect(host).await?;
    if let Err(error) = ensure_remote_ghostty_terminfo(&client).await {
        tracing::warn!(
            "Failed to sync Ghostty terminfo to {}: {}",
            client.host_alias,
            error
        );
    }

    if allow_deploy {
        ensure_deployed(&client).await?;
        let tunnel = Tunnel::start(&client.host_alias, 7680).await?;
        return Ok((client, tunnel));
    }

    let tunnel = Tunnel::start(&client.host_alias, 7680).await?;
    connect_without_deploy(client, tunnel).await
}

async fn connect_without_deploy(
    client: SshClient,
    tunnel: Tunnel,
) -> Result<(SshClient, Tunnel), ConnectError> {
    match validate_existing_remote_tunnel(&client, tunnel.local_port).await {
        Ok(()) => Ok((client, tunnel)),
        Err(error) => {
            tunnel.close().await;
            Err(error)
        }
    }
}

async fn validate_existing_remote_tunnel(
    client: &SshClient,
    tunnel_port: u16,
) -> Result<(), ConnectError> {
    match probe_remote_server(tunnel_port).await {
        RemoteProbe::ReadyCurrentVersion => return Ok(()),
        RemoteProbe::ReadyStaleVersion => return Err(ConnectError::UpgradeRequired),
        RemoteProbe::Unreachable => {}
    }

    if ensure_started_without_restart(&client).await.is_ok() {
        return match probe_remote_server(tunnel_port).await {
            RemoteProbe::ReadyCurrentVersion => Ok(()),
            RemoteProbe::ReadyStaleVersion => Err(ConnectError::UpgradeRequired),
            RemoteProbe::Unreachable => Err(ConnectError::Other(anyhow::anyhow!(
                "remote daemon bootstrap finished but the server is still unreachable"
            ))),
        };
    }

    let version = remote_binary_version(&client).await?;
    if version
        .as_deref()
        .map(|value| value.contains(env!("CARGO_PKG_VERSION")))
        .unwrap_or(false)
    {
        return Err(ConnectError::Other(anyhow::anyhow!(
            "remote daemon is not running and automatic bootstrap failed; use --restart-remote for a forced cleanup"
        )));
    }

    match version {
        Some(_) => Err(ConnectError::UpgradeRequired),
        None => Err(ConnectError::Other(anyhow::anyhow!(
            "remote daemon is not installed and automatic bootstrap failed"
        ))),
    }
}

pub async fn run_scanner(manager: RemoteManager) {
    scan_hosts(&manager).await;

    let mut interval = tokio::time::interval(Duration::from_secs(60));
    interval.tick().await;
    loop {
        interval.tick().await;
        scan_hosts(&manager).await;
    }
}

async fn scan_hosts(manager: &RemoteManager) {
    let hosts = parse_ssh_config("~/.ssh/config");
    if hosts.is_empty() {
        return;
    }

    for host in &hosts {
        manager
            .hosts
            .entry(host.host.clone())
            .or_insert_with(|| RemoteHostState {
                ssh_host: host.clone(),
                status: RemoteStatus::Unreachable,
                client: None,
                tunnel: None,
            });
    }

    let mut tasks = Vec::new();
    for host in hosts {
        let manager = manager.clone();
        tasks.push(tokio::spawn(async move {
            let alias = host.host.clone();

            if let Some(entry) = manager.hosts.get(&alias) {
                if entry.status == RemoteStatus::Connecting {
                    return;
                }
                if entry.status == RemoteStatus::Ready {
                    if let Some(tunnel) = entry.tunnel.as_ref() {
                        if is_port_alive(tunnel.local_port).await {
                            return;
                        }
                    }
                }
            }

            if !is_host_reachable(&host).await {
                manager.set_status(&alias, RemoteStatus::Unreachable);
                return;
            }

            manager.set_status(&alias, RemoteStatus::Connecting);
            match connect_remote(&host, manager.allow_deploy).await {
                Ok((client, tunnel)) => {
                    let tunnel_port = tunnel.local_port;
                    if let Some(mut entry) = manager.hosts.get_mut(&alias) {
                        entry.status = RemoteStatus::Ready;
                        entry.client = Some(client);
                        entry.tunnel = Some(tunnel);
                    }
                    let _ = manager.ready_tx.send((alias, tunnel_port));
                }
                Err(ConnectError::UpgradeRequired) => {
                    manager.set_status(&alias, RemoteStatus::UpgradeRequired);
                }
                Err(ConnectError::Other(error)) => {
                    tracing::warn!("Failed to connect to {}: {}", alias, error);
                    manager.set_status(&alias, RemoteStatus::Failed(error.to_string()));
                }
            }
        }));
    }

    for task in tasks {
        let _ = task.await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{routing::get, Json, Router};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    #[derive(serde::Serialize)]
    struct MockInfo {
        name: String,
        version: String,
        sessions_count: usize,
    }

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
        let manager = RemoteManager::new();
        assert!(manager.list_statuses().is_empty());
    }

    #[test]
    fn get_tunnel_port_unknown_host_returns_none() {
        let manager = RemoteManager::new();
        assert!(manager.get_tunnel_port("nope").is_none());
    }

    #[tokio::test]
    async fn list_ready_hosts_only_returns_ready_entries() {
        let manager = RemoteManager::new();
        manager.hosts.insert(
            "a".to_string(),
            RemoteHostState {
                ssh_host: make_host("a"),
                status: RemoteStatus::Ready,
                client: None,
                tunnel: Some(Tunnel::new_for_testing(5555)),
            },
        );
        manager.hosts.insert(
            "b".to_string(),
            RemoteHostState {
                ssh_host: make_host("b"),
                status: RemoteStatus::Failed("boom".to_string()),
                client: None,
                tunnel: None,
            },
        );
        assert_eq!(manager.list_ready_hosts(), vec![("a".to_string(), 5555)]);
    }

    #[tokio::test]
    async fn inject_ready_for_testing_exposes_port() {
        let manager = RemoteManager::new();
        manager.inject_ready_for_testing("myhost", 6000);
        assert_eq!(manager.get_tunnel_port("myhost"), Some(6000));
    }

    #[tokio::test]
    async fn clear_dead_tunnel_resets_ready_host() {
        let manager = RemoteManager::new();
        manager.inject_ready_for_testing("ready", 7000);
        manager.clear_dead_tunnel("ready");
        let statuses = manager.list_statuses();
        assert!(matches!(statuses[0].status, RemoteStatus::Unreachable));
        assert!(statuses[0].tunnel_port.is_none());
    }

    #[test]
    fn new_with_deploy_sets_flag() {
        let manager = RemoteManager::new_with_deploy(true);
        assert!(manager.allow_deploy);
    }

    async fn start_info_server(version: &str) -> u16 {
        async fn info_handler(
            axum::extract::State(version): axum::extract::State<String>,
        ) -> Json<MockInfo> {
            Json(MockInfo {
                name: "tether".to_string(),
                version,
                sessions_count: 0,
            })
        }

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let app = Router::new()
            .route("/api/info", get(info_handler))
            .with_state(version.to_string());
        tokio::spawn(async move {
            axum::serve(listener, app).await.ok();
        });
        tokio::time::sleep(Duration::from_millis(10)).await;
        port
    }

    #[tokio::test]
    async fn probe_remote_server_rejects_stale_versions() {
        let current_port = start_info_server(env!("CARGO_PKG_VERSION")).await;
        let stale_port = start_info_server("0.0.1").await;

        assert_eq!(
            probe_remote_server(current_port).await,
            RemoteProbe::ReadyCurrentVersion
        );
        assert_eq!(
            probe_remote_server(stale_port).await,
            RemoteProbe::ReadyStaleVersion
        );
    }

    #[tokio::test]
    async fn stale_remote_attempts_close_tunnel_every_time() {
        let stale_port = start_info_server("0.0.1").await;
        let close_counter = Arc::new(AtomicUsize::new(0));

        let first = connect_without_deploy(
            SshClient {
                host_alias: "stale".to_string(),
            },
            Tunnel::new_for_testing_with_close_counter(stale_port, close_counter.clone()),
        )
        .await;
        let second = connect_without_deploy(
            SshClient {
                host_alias: "stale".to_string(),
            },
            Tunnel::new_for_testing_with_close_counter(stale_port, close_counter.clone()),
        )
        .await;

        assert!(matches!(first, Err(ConnectError::UpgradeRequired)));
        assert!(matches!(second, Err(ConnectError::UpgradeRequired)));
        assert_eq!(close_counter.load(Ordering::SeqCst), 2);
    }
}
