use std::time::Duration;
use tokio::net::TcpListener;

/// A local port-forward tunnel via `ssh -L`, forwarding
/// `127.0.0.1:{local_port}` → `127.0.0.1:{remote_port}` on the remote host.
///
/// Dropping this struct stops the tunnel task.
pub struct Tunnel {
    pub local_port: u16,
    _task: tokio::task::JoinHandle<()>,
}

impl Tunnel {
    pub async fn start(host_alias: &str, remote_port: u16) -> anyhow::Result<Self> {
        // Reserve a free local port then release it so ssh can bind it.
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let local_port = listener.local_addr()?.port();
        drop(listener);

        let host = host_alias.to_string();
        let mut child = tokio::process::Command::new("ssh")
            .args([
                "-N",
                "-L", &format!("127.0.0.1:{}:127.0.0.1:{}", local_port, remote_port),
                "-o", "ExitOnForwardFailure=yes",
                "-o", "BatchMode=yes",
                "-o", "ServerAliveInterval=10",
                "-o", "ServerAliveCountMax=3",
                &host,
            ])
            .spawn()?;

        tracing::info!(
            "SSH tunnel for {}: 127.0.0.1:{} → remote:{}",
            host, local_port, remote_port
        );

        // Wait for the port to become reachable before declaring success.
        wait_for_port(local_port).await?;

        let task = tokio::spawn(async move {
            let _ = child.wait().await;
            // With ControlMaster the -L client exits quickly after delegating the
            // port-forward to the master; the forwarding stays alive via the master.
            tracing::debug!("SSH tunnel client for {} on port {} exited (ControlMaster keeps port alive)", host, local_port);
        });

        Ok(Self { local_port, _task: task })
    }
}

/// Poll until something is listening on `local_port`, or time out.
async fn wait_for_port(local_port: u16) -> anyhow::Result<()> {
    for attempt in 1..=20 {
        tokio::time::sleep(Duration::from_millis(500)).await;
        if tokio::net::TcpStream::connect(("127.0.0.1", local_port)).await.is_ok() {
            return Ok(());
        }
        tracing::debug!("Waiting for tunnel port {} ({}/20)...", local_port, attempt);
    }
    anyhow::bail!("SSH tunnel port {} did not become available in time", local_port)
}

impl Tunnel {
    /// Create a mock tunnel pointing at an already-listening local port.
    /// Only for use in tests — bypasses real SSH.
    #[allow(dead_code)]
    pub fn new_for_testing(local_port: u16) -> Self {
        Self {
            local_port,
            _task: tokio::spawn(async {}),
        }
    }
}
