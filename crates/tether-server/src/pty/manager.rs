use crate::pty::session::PtySession;
use crate::state::AppState;
use std::sync::Arc;
use uuid::Uuid;

/// Resolve the effective shell command and cwd for session spawning.
/// For SSH groups with a non-home remote cwd, wraps the ssh command
/// to cd into the remote path. Returns (effective_shell, effective_cwd)
/// for spawning, plus the original (shell, cwd) for DB storage.
pub fn resolve_ssh_command(
    ssh_host: Option<&str>,
    shell: &str,
    cwd: &str,
) -> (String, String) {
    if ssh_host.is_some() && shell.starts_with("ssh ") {
        let shell_with_keepalive = shell.replacen(
            "ssh ",
            "ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o IPQoS=lowdelay ",
            1,
        );
        let ssh_cmd = if cwd != "~" && !cwd.is_empty() {
            format!("{} -t \"cd {} && exec \\$SHELL -l\"", shell_with_keepalive, cwd)
        } else {
            shell_with_keepalive
        };
        let local_cwd = shellexpand::tilde("~").to_string();
        (ssh_cmd, local_cwd)
    } else {
        (shell.to_string(), cwd.to_string())
    }
}

impl AppState {
    pub fn create_session(
        &self,
        group_id: Uuid,
        name: Option<String>,
        command: Option<String>,
        cwd_override: Option<String>,
    ) -> anyhow::Result<Arc<PtySession>> {
        let inner = &self.inner;
        let group = inner
            .db
            .get_group(&group_id.to_string())?
            .ok_or_else(|| anyhow::anyhow!("Group not found"))?;

        let id = Uuid::new_v4();
        let shell = command
            .filter(|c| !c.is_empty())
            .unwrap_or_else(|| inner.config.resolve_shell());
        let cwd = cwd_override
            .filter(|c| !c.is_empty())
            .unwrap_or_else(|| group.default_cwd.clone());
        let session_name = name.unwrap_or_else(|| format!("session-{}", &id.to_string()[..8]));
        let data_dir = inner.config.data_dir();

        // For SSH sessions: embed remote cwd into SSH command, use local home for process cwd
        let (effective_shell, effective_cwd) =
            resolve_ssh_command(group.ssh_host.as_deref(), &shell, &cwd);

        let session = PtySession::spawn(
            id,
            group_id,
            &session_name,
            &effective_shell,
            &effective_cwd,
            80,
            24,
            &data_dir,
            inner.config.terminal.scrollback_memory_kb,
            inner.config.terminal.scrollback_disk_max_mb,
        )?;

        // Persist to DB
        inner.db.create_session(
            &id.to_string(),
            &group_id.to_string(),
            &session_name,
            &shell,
            &cwd,
        )?;

        inner.sessions.insert(id, session.clone());
        tracing::info!("Created session {} ({})", session_name, id);
        Ok(session)
    }

    pub fn kill_session(&self, session_id: Uuid) -> anyhow::Result<()> {
        if let Some((_, session)) = self.inner.sessions.remove(&session_id) {
            session.kill();
            session.flush_scrollback();
        }
        self.inner.db.delete_session(&session_id.to_string())?;
        // Clean up scrollback files
        let session_dir = format!(
            "{}/sessions/{}",
            self.inner.config.data_dir(),
            session_id
        );
        std::fs::remove_dir_all(&session_dir).ok();
        tracing::info!("Killed and removed session {}", session_id);
        Ok(())
    }

    pub fn get_session(&self, session_id: Uuid) -> Option<Arc<PtySession>> {
        self.inner.sessions.get(&session_id).map(|s| s.clone())
    }
}
