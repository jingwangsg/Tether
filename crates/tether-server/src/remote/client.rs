use crate::ssh_config::SshHost;

/// Thin wrapper around the system `ssh` command.
///
/// By delegating all operations to the system `ssh` binary, we automatically
/// benefit from ControlMaster multiplexing, SSH agent forwarding, ProxyJump,
/// GSSAPI, certificates, and every other auth mechanism the user has configured
/// in `~/.ssh/config` — without reimplementing any of it.
pub struct SshClient {
    pub host_alias: String,
}

impl SshClient {
    /// Verify that the host is reachable and auth works by running `true` on
    /// the remote.  Uses BatchMode to avoid hanging on interactive prompts.
    pub async fn connect(host: &SshHost) -> anyhow::Result<Self> {
        let output = tokio::process::Command::new("ssh")
            .args([
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=10",
                &host.host,
                "true",
            ])
            .output()
            .await?;

        if !output.status.success() {
            anyhow::bail!(
                "SSH test connection to {} failed: {}",
                host.host,
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }

        tracing::info!("SSH connected to {}", host.host);
        Ok(Self {
            host_alias: host.host.clone(),
        })
    }

    /// Run a command on the remote and return `(exit_code, stdout, stderr)`.
    pub async fn exec(&self, cmd: &str) -> anyhow::Result<(u32, String, String)> {
        let output = tokio::process::Command::new("ssh")
            .args(["-o", "BatchMode=yes", &self.host_alias, cmd])
            .output()
            .await?;

        Ok((
            output.status.code().unwrap_or(1) as u32,
            String::from_utf8_lossy(&output.stdout).into_owned(),
            String::from_utf8_lossy(&output.stderr).into_owned(),
        ))
    }

    /// Run a command on the remote and fail if it exits non-zero.
    pub async fn exec_checked(&self, cmd: &str) -> anyhow::Result<(String, String)> {
        let (code, stdout, stderr) = self.exec(cmd).await?;
        if code != 0 {
            anyhow::bail!(
                "Remote command on {} failed with exit {}: {}",
                self.host_alias,
                code,
                stderr.trim()
            );
        }
        Ok((stdout, stderr))
    }

    /// Upload `data` to `remote_path` by piping through `cat` over SSH.
    pub async fn upload(&self, data: &[u8], remote_path: &str) -> anyhow::Result<()> {
        use tokio::io::AsyncWriteExt;

        let quoted_path = shell_path(remote_path);
        let mut child = tokio::process::Command::new("ssh")
            .args([
                "-o",
                "BatchMode=yes",
                &self.host_alias,
                &format!("cat > {}", quoted_path),
            ])
            .stdin(std::process::Stdio::piped())
            .spawn()?;

        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(data).await?;
        }

        let status = child.wait().await?;
        if !status.success() {
            anyhow::bail!("Upload to {} failed", self.host_alias);
        }
        Ok(())
    }
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', r#"'\''"#))
}

fn shell_path(value: &str) -> String {
    if value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '/' | '.' | '_' | '-' | '~'))
    {
        value.to_string()
    } else {
        shell_quote(value)
    }
}

#[cfg(test)]
mod tests {
    use super::shell_path;

    #[test]
    fn shell_path_leaves_tilde_prefixed_paths_unquoted() {
        assert_eq!(
            shell_path("~/.tether/bin/tether-server"),
            "~/.tether/bin/tether-server"
        );
    }

    #[test]
    fn shell_path_quotes_paths_with_spaces() {
        assert_eq!(
            shell_path("/tmp/tether bundle/server binary"),
            "'/tmp/tether bundle/server binary'"
        );
    }
}
