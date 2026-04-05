use std::time::Duration;
use tokio::net::TcpListener;
use tokio::sync::oneshot;

/// A local port-forward tunnel via `ssh -L`, forwarding
/// `127.0.0.1:{local_port}` → `127.0.0.1:{remote_port}` on the remote host.
///
/// Dropping this struct stops the tunnel task.
pub struct Tunnel {
    pub local_port: u16,
    shutdown_tx: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<()>>,
}

impl Tunnel {
    pub async fn start(host_alias: &str, remote_port: u16) -> anyhow::Result<Self> {
        // Reserve a free local port then release it so ssh can bind it.
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let local_port = listener.local_addr()?.port();
        drop(listener);

        let host = host_alias.to_string();
        let args = ssh_tunnel_args(&host, local_port, remote_port);
        let mut child = tokio::process::Command::new("ssh").args(&args).spawn()?;

        tracing::info!(
            "SSH tunnel for {}: 127.0.0.1:{} → remote:{}",
            host,
            local_port,
            remote_port
        );

        // Wait for the port to become reachable before declaring success.
        if let Err(error) = wait_for_port(local_port).await {
            let _ = child.start_kill();
            let _ = child.wait().await;
            return Err(error);
        }

        let (shutdown_tx, mut shutdown_rx) = oneshot::channel();

        let task = tokio::spawn(async move {
            tokio::select! {
                status = child.wait() => {
                    let _ = status;
                    tracing::debug!(
                        "SSH tunnel client for {} on port {} exited",
                        host,
                        local_port
                    );
                }
                _ = &mut shutdown_rx => {
                    let _ = child.start_kill();
                    let _ = child.wait().await;
                    tracing::debug!(
                        "SSH tunnel client for {} on port {} was shut down",
                        host,
                        local_port
                    );
                }
            }
        });

        Ok(Self {
            local_port,
            shutdown_tx: Some(shutdown_tx),
            task: Some(task),
        })
    }

    pub async fn close(mut self) {
        self.signal_shutdown();
        if let Some(task) = self.task.take() {
            let _ = task.await;
        }
    }

    fn signal_shutdown(&mut self) {
        if let Some(shutdown_tx) = self.shutdown_tx.take() {
            let _ = shutdown_tx.send(());
        }
    }
}

fn ssh_tunnel_args(host_alias: &str, local_port: u16, remote_port: u16) -> Vec<String> {
    vec![
        "-N".to_string(),
        "-L".to_string(),
        format!("127.0.0.1:{local_port}:127.0.0.1:{remote_port}"),
        "-S".to_string(),
        "none".to_string(),
        "-o".to_string(),
        "ControlMaster=no".to_string(),
        "-o".to_string(),
        "ExitOnForwardFailure=yes".to_string(),
        "-o".to_string(),
        "BatchMode=yes".to_string(),
        "-o".to_string(),
        "StrictHostKeyChecking=no".to_string(),
        "-o".to_string(),
        "UserKnownHostsFile=/dev/null".to_string(),
        "-o".to_string(),
        "ServerAliveInterval=10".to_string(),
        "-o".to_string(),
        "ServerAliveCountMax=3".to_string(),
        host_alias.to_string(),
    ]
}

/// Poll until something is listening on `local_port`, or time out.
async fn wait_for_port(local_port: u16) -> anyhow::Result<()> {
    for attempt in 1..=20 {
        tokio::time::sleep(Duration::from_millis(500)).await;
        if tokio::net::TcpStream::connect(("127.0.0.1", local_port))
            .await
            .is_ok()
        {
            return Ok(());
        }
        tracing::debug!("Waiting for tunnel port {} ({}/20)...", local_port, attempt);
    }
    anyhow::bail!(
        "SSH tunnel port {} did not become available in time",
        local_port
    )
}

impl Tunnel {
    /// Create a mock tunnel pointing at an already-listening local port.
    /// Only for use in tests — bypasses real SSH.
    #[allow(dead_code)]
    pub fn new_for_testing(local_port: u16) -> Self {
        let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
        let task = tokio::spawn(async move {
            let _ = (&mut shutdown_rx).await;
        });
        Self {
            local_port,
            shutdown_tx: Some(shutdown_tx),
            task: Some(task),
        }
    }

    #[cfg(test)]
    pub fn new_for_testing_with_close_counter(
        local_port: u16,
        close_counter: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    ) -> Self {
        let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
        let task = tokio::spawn(async move {
            let _ = (&mut shutdown_rx).await;
            close_counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        });
        Self {
            local_port,
            shutdown_tx: Some(shutdown_tx),
            task: Some(task),
        }
    }
}

impl Drop for Tunnel {
    fn drop(&mut self) {
        self.signal_shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ssh_tunnel_args_disable_connection_sharing() {
        let args = ssh_tunnel_args("shared-host", 41000, 7680);

        assert!(args.windows(2).any(|window| window == ["-S", "none"]));
        assert!(args
            .windows(2)
            .any(|window| window == ["-o", "ControlMaster=no"]));
        assert!(args
            .windows(2)
            .any(|window| window == ["-o", "StrictHostKeyChecking=no"]));
        assert!(args
            .windows(2)
            .any(|window| window == ["-o", "UserKnownHostsFile=/dev/null"]));
        assert_eq!(args.last().map(String::as_str), Some("shared-host"));
    }
}
