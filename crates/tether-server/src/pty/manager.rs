use crate::config::ssh_terminfo_preamble;
use crate::pty::session::{PtySession, PtyTerminalEnv};
use crate::state::AppState;
use std::sync::Arc;
use uuid::Uuid;

/// POSIX single-quote escaping for a shell path argument.
///
/// For `~/...` paths the tilde-slash prefix is kept *outside* the single-quote
/// block so the remote shell expands it to `$HOME`.  The rest of the path is
/// single-quoted to prevent word splitting and metacharacter injection.
///
/// Examples:
///   `~/my projects`   → `~/'my projects'`
///   `/opt/my app`     → `'/opt/my app'`
///   `~/it's here`     → `~/'it'\''s here'`
fn shell_quote(s: &str) -> String {
    if let Some(rest) = s.strip_prefix("~/") {
        // Keep ~/ unquoted for tilde expansion; single-quote the path component.
        format!("~/{}", single_quote(rest))
    } else {
        single_quote(s)
    }
}

fn single_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ShellKind {
    Bash,
    Zsh,
}

fn detect_shell_kind(shell: &str) -> Option<ShellKind> {
    if shell.contains(' ') {
        return None;
    }

    let shell_name = std::path::Path::new(shell)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(shell);

    match shell_name {
        "bash" => Some(ShellKind::Bash),
        "zsh" => Some(ShellKind::Zsh),
        _ => None,
    }
}

/// Resolve the effective shell command and cwd for session spawning.
/// For SSH groups with a non-home remote cwd, wraps the ssh command
/// to cd into the remote path. Returns (effective_shell, effective_cwd)
/// for spawning, plus the original (shell, cwd) for DB storage.
pub fn resolve_ssh_command(ssh_host: Option<&str>, shell: &str, cwd: &str) -> (String, String) {
    if ssh_host.is_some() && shell.starts_with("ssh ") {
        let shell_with_keepalive = shell.replacen(
            "ssh ",
            "ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o IPQoS=lowdelay ",
            1,
        );
        let ssh_cmd = if cwd != "~" && !cwd.is_empty() {
            // Install xterm-ghostty terminfo on the remote before starting
            // the shell.  SSH forwards TERM but not TERMINFO, so without
            // this TUI apps that rely on terminfo (gdu, htop, etc.) fail.
            let ti_preamble = ssh_terminfo_preamble();
            format!(
                "{} -t \"{}; cd {} && exec \\$SHELL -l\"",
                shell_with_keepalive,
                ti_preamble,
                shell_quote(cwd)
            )
        } else {
            // When cwd is ~ or empty, use plain SSH so sshd starts the
            // user's login shell directly.  This avoids sending POSIX
            // syntax that would break non-POSIX remote shells (fish, tcsh).
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
        id_override: Option<Uuid>,
    ) -> anyhow::Result<Arc<PtySession>> {
        let inner = &self.inner;
        let group = inner
            .db
            .get_group(&group_id.to_string())?
            .ok_or_else(|| anyhow::anyhow!("Group not found"))?;

        let id = id_override.unwrap_or_else(Uuid::new_v4);
        let is_default_shell = command.as_ref().map_or(true, |c| c.is_empty());
        let shell = command
            .as_ref()
            .filter(|c| !c.is_empty())
            .cloned()
            .unwrap_or_else(|| inner.config.resolve_shell());
        let cwd = cwd_override
            .filter(|c| !c.is_empty())
            .unwrap_or_else(|| group.default_cwd.clone());
        let session_name = name.unwrap_or_else(|| format!("session-{}", &id.to_string()[..8]));
        let data_dir = inner.config.data_dir();

        // For SSH sessions: embed remote cwd into SSH command, use local home for process cwd
        let (effective_shell, effective_cwd) =
            resolve_ssh_command(group.ssh_host.as_deref(), &shell, &cwd);
        let mut terminal_env = PtyTerminalEnv {
            vars: inner.config.ghostty_terminal_env()?,
        };
        let spawned_shell = if is_default_shell {
            match detect_shell_kind(&effective_shell) {
                Some(ShellKind::Zsh) => {
                    terminal_env
                        .vars
                        .push(("TETHER_REAL_SHELL".to_string(), effective_shell.clone()));
                    if let Ok(real_zdotdir) = std::env::var("ZDOTDIR") {
                        if !real_zdotdir.is_empty() {
                            terminal_env
                                .vars
                                .push(("TETHER_REAL_ZDOTDIR".to_string(), real_zdotdir));
                        }
                    }
                    inner.config.zsh_wrapper_path().display().to_string()
                }
                Some(ShellKind::Bash) => {
                    terminal_env
                        .vars
                        .push(("TETHER_REAL_SHELL".to_string(), effective_shell.clone()));
                    inner.config.bash_wrapper_path().display().to_string()
                }
                None => effective_shell.clone(),
            }
        } else {
            effective_shell.clone()
        };

        let session = PtySession::spawn(
            id,
            group_id,
            &session_name,
            &spawned_shell,
            &effective_cwd,
            80,
            24,
            &data_dir,
            inner.config.terminal.scrollback_memory_kb,
            inner.config.terminal.scrollback_disk_max_mb,
            terminal_env,
            inner.semantic_event_tx.clone(),
        )?;

        // Persist to DB
        inner.db.create_session(
            &id.to_string(),
            &group_id.to_string(),
            &session_name,
            &shell,
            &cwd,
            None,
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
        let session_dir = format!("{}/sessions/{}", self.inner.config.data_dir(), session_id);
        std::fs::remove_dir_all(&session_dir).ok();
        tracing::info!("Killed and removed session {}", session_id);
        Ok(())
    }

    pub fn get_session(&self, session_id: Uuid) -> Option<Arc<PtySession>> {
        self.inner.sessions.get(&session_id).map(|s| s.clone())
    }
}
