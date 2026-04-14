//! E2E tests for SSH host session creation logic.
//!
//! Tests the command transformation that ensures:
//! - SSH sessions cd into the remote path
//! - Local home is used as process cwd (not the remote path)
//! - DB stores original command/cwd for display
//! - Edge cases (bare ~, empty cwd, non-SSH commands) are handled

use tether_server::pty::manager::resolve_ssh_command;

// --- SSH command transformation ---

#[test]
fn ssh_with_remote_cwd_includes_cd() {
    let (shell, cwd) = resolve_ssh_command(Some("devbox"), "ssh devbox", "~/projects");

    assert!(
        shell.contains("cd ~/'projects'"),
        "should contain properly quoted cd, got: {}",
        shell
    );
    assert!(
        shell.contains("-t"),
        "should include -t for tty allocation, got: {}",
        shell
    );
    assert!(
        shell.contains("exec \\$SHELL -l"),
        "should exec login shell, got: {}",
        shell
    );
    assert!(
        shell.contains("devbox"),
        "should contain host, got: {}",
        shell
    );
    assert!(
        shell.contains("ServerAliveInterval=30"),
        "should contain keepalive option, got: {}",
        shell
    );
    // cwd should be local home, not the remote path
    let home = shellexpand::tilde("~").to_string();
    assert_eq!(cwd, home, "process cwd should be local home");
}

#[test]
fn ssh_with_home_cwd_skips_cd() {
    let (shell, cwd) = resolve_ssh_command(Some("devbox"), "ssh devbox", "~");

    // When cwd is ~, no cd is needed but terminfo preamble + exec $SHELL -l are still injected.
    assert!(
        shell.starts_with("ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o IPQoS=lowdelay devbox -t"),
        "should be ssh command with keepalive and -t, got: {}",
        &shell[..shell.len().min(120)]
    );
    assert!(
        !shell.contains("cd "),
        "should not contain cd when cwd is ~"
    );
    assert!(
        shell.contains("exec \\$SHELL -l"),
        "should exec login shell"
    );
    assert!(
        shell.contains("terminfo"),
        "should contain terminfo setup preamble"
    );
    let home = shellexpand::tilde("~").to_string();
    assert_eq!(cwd, home);
}

#[test]
fn ssh_with_empty_cwd_skips_cd() {
    let (shell, cwd) = resolve_ssh_command(Some("devbox"), "ssh devbox", "");

    assert!(
        shell.starts_with("ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o IPQoS=lowdelay devbox -t"),
        "empty cwd should use -t with terminfo preamble, got: {}",
        &shell[..shell.len().min(120)]
    );
    assert!(
        !shell.contains("cd "),
        "should not contain cd when cwd is empty"
    );
    assert!(
        shell.contains("exec \\$SHELL -l"),
        "should exec login shell"
    );
    let home = shellexpand::tilde("~").to_string();
    assert_eq!(cwd, home);
}

#[test]
fn ssh_with_absolute_remote_path() {
    let (shell, _) = resolve_ssh_command(Some("prod"), "ssh prod", "/opt/app");

    assert!(
        shell.contains("cd '/opt/app'"),
        "should handle absolute remote path (quoted), got: {}",
        shell
    );
}

#[test]
fn ssh_with_deep_nested_path() {
    let (shell, _) = resolve_ssh_command(Some("devbox"), "ssh devbox", "~/a/b/c/d");

    assert!(
        shell.contains("cd ~/'a/b/c/d'"),
        "should handle deeply nested path (quoted), got: {}",
        shell
    );
}

#[test]
fn ssh_preserves_host_with_user() {
    let (shell, _) = resolve_ssh_command(Some("myhost"), "ssh user@myhost", "~/work");

    assert!(
        shell.contains("user@myhost"),
        "should preserve user@host, got: {}",
        shell
    );
    assert!(shell.contains("cd ~/'work'"));
}

#[test]
fn ssh_preserves_host_with_port() {
    let (shell, _) = resolve_ssh_command(Some("myhost"), "ssh -p 2222 myhost", "~/work");

    assert!(
        shell.contains("-p 2222") && shell.contains("myhost"),
        "should preserve port flag, got: {}",
        shell
    );
    assert!(shell.contains("cd ~/'work'"));
}

// --- Non-SSH commands are not transformed ---

#[test]
fn local_session_not_transformed() {
    let (shell, cwd) = resolve_ssh_command(None, "/bin/zsh", "~/projects");

    assert_eq!(shell, "/bin/zsh", "local shell should not be modified");
    assert_eq!(cwd, "~/projects", "local cwd should not be modified");
}

#[test]
fn non_ssh_command_with_ssh_host_not_transformed() {
    // Group has ssh_host set, but command is not "ssh ..."
    let (shell, cwd) = resolve_ssh_command(Some("devbox"), "htop", "~/projects");

    assert_eq!(shell, "htop", "non-ssh command should not be transformed");
    assert_eq!(cwd, "~/projects");
}

#[test]
fn no_ssh_host_with_ssh_command_not_transformed() {
    // ssh_host is None but command happens to be "ssh ..."
    let (shell, cwd) = resolve_ssh_command(None, "ssh devbox", "~/projects");

    assert_eq!(
        shell, "ssh devbox",
        "without ssh_host, command should not be transformed"
    );
    assert_eq!(cwd, "~/projects");
}

#[test]
fn empty_command_not_transformed() {
    let (shell, cwd) = resolve_ssh_command(Some("devbox"), "/bin/bash", "~");

    assert_eq!(shell, "/bin/bash");
    assert_eq!(cwd, "~");
}

// --- DB storage: verify original values are preserved ---
// (These test the contract that create_session stores shell/cwd, not effective_*)

#[test]
fn transformation_returns_different_values_than_originals() {
    let original_shell = "ssh devbox";
    let original_cwd = "~/projects";

    let (effective_shell, effective_cwd) =
        resolve_ssh_command(Some("devbox"), original_shell, original_cwd);

    // Effective shell should differ from original (has cd wrapper)
    assert_ne!(
        effective_shell, original_shell,
        "effective shell should differ from original"
    );
    // Effective cwd should differ from original (local home vs remote path)
    assert_ne!(
        effective_cwd, original_cwd,
        "effective cwd should differ from original"
    );

    // Original values should be used for DB storage (tested at call site)
    assert_eq!(original_shell, "ssh devbox");
    assert_eq!(original_cwd, "~/projects");
}

// --- Full command string format validation ---

#[test]
fn full_command_format_is_correct() {
    let (shell, _) = resolve_ssh_command(Some("devbox"), "ssh devbox", "~/work");

    // The command now includes a terminfo installation preamble before the cd.
    // ~/ prefix stays unquoted for tilde expansion; path component is single-quoted.
    assert!(
        shell.starts_with(r#"ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o IPQoS=lowdelay devbox -t ""#),
        "full command format should start correctly, got: {}",
        &shell[..shell.len().min(120)]
    );
    assert!(
        shell.ends_with(r#"; cd ~/'work' && exec \$SHELL -l""#),
        "full command format should end with cd and exec, got: {}",
        &shell[shell.len().saturating_sub(80)..]
    );
    // Verify the terminfo preamble structure
    assert!(
        shell.contains("if [ ! -s \\$HOME/.terminfo/x/xterm-ghostty ]"),
        "should contain terminfo existence check (using -s for non-zero size)"
    );
    assert!(
        shell.contains("base64 -d"),
        "should contain base64 decode step"
    );
    assert!(
        shell.contains("tic -x"),
        "should contain tic compilation step"
    );
}

#[test]
fn full_command_format_with_absolute_path() {
    let (shell, _) = resolve_ssh_command(Some("prod"), "ssh prod", "/var/app");

    assert!(
        shell.starts_with(r#"ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o IPQoS=lowdelay prod -t ""#),
        "should start with correct ssh command"
    );
    assert!(
        shell.ends_with(r#"; cd '/var/app' && exec \$SHELL -l""#),
        "should end with cd to absolute path and exec, got: {}",
        &shell[shell.len().saturating_sub(80)..]
    );
}

// --- Edge case: paths that must be shell-quoted ---

#[test]
fn path_with_spaces() {
    let (shell, _) = resolve_ssh_command(Some("devbox"), "ssh devbox", "~/my projects");

    assert!(
        shell.contains("cd ~/'my projects'"),
        "path with spaces: ~/ unquoted, rest single-quoted, got: {}",
        shell
    );
}

#[test]
fn path_with_shell_metacharacters() {
    let (shell, _) = resolve_ssh_command(Some("devbox"), "ssh devbox", "~/projects/$(evil)");

    assert!(
        shell.contains("cd ~/'projects/$(evil)'"),
        "metacharacters must be single-quoted, got: {}",
        shell
    );
    // The $() must NOT appear unquoted
    assert!(
        !shell.contains("cd ~/projects/$(evil)"),
        "unquoted metacharacters must not appear in command"
    );
}

#[test]
fn bare_tilde_slash_produces_valid_shell() {
    // shell_quote("~/") → ~/'' — the trailing '' is a no-op and the result is valid shell.
    let (shell, _) = resolve_ssh_command(Some("devbox"), "ssh devbox", "~/");

    // resolve_ssh_command skips cd when cwd == "~", so "~/" should produce the cd wrapper.
    // shell_quote("~/") strips "~/" prefix, single_quote("") = '' → result is ~/''
    assert!(
        shell.contains("cd ~/''") || shell.contains("cd ~/"),
        "bare tilde-slash must produce valid shell, got: {}",
        shell
    );
}

#[test]
fn path_with_embedded_single_quote() {
    let (shell, _) = resolve_ssh_command(Some("devbox"), "ssh devbox", "~/it's a path");

    // Single quote inside the path component must be escaped via '\''
    // ~/ stays unquoted; the rest is: 'it'\''s a path'
    assert!(
        shell.contains("cd ~/'it'\\''s a path'"),
        "embedded single quote must be escaped, got: {}",
        shell
    );
}

// --- API-level test: session creation stores originals in DB ---

use dashmap::DashMap;
use std::sync::Arc;
use tether_server::config::{PersistenceSection, ServerConfig, ServerSection, TerminalSection};
use tether_server::persistence::Store;
use tether_server::state::{AppState, AppStateInner};

fn test_state() -> AppState {
    let data_dir = std::env::temp_dir()
        .join(format!("tether-ssh-test-{}", uuid::Uuid::new_v4()))
        .to_string_lossy()
        .to_string();
    std::fs::create_dir_all(&data_dir).unwrap();

    let config = ServerConfig {
        server: ServerSection {
            bind: "127.0.0.1".to_string(),
            port: 0,
            auth_token: None,
        },
        persistence: PersistenceSection {
            data_dir: data_dir.clone(),
        },
        terminal: TerminalSection::default(),
    };

    let db_path = format!("{}/tether.db", data_dir);
    let db = Store::new(&db_path).unwrap();
    db.init_tables().unwrap();

    let (shutdown_tx, _) = tokio::sync::broadcast::channel(1);
    let (status_tx, _) = tokio::sync::broadcast::channel(64);

    AppState {
        inner: Arc::new(AppStateInner {
            config,
            sessions: DashMap::new(),
            db,
            shutdown_tx,
            status_tx,
            remote_manager: tether_server::remote::manager::RemoteManager::new(),
            ssh_fg: DashMap::new(),
            ssh_live_sessions: DashMap::new(),
            semantic_event_tx: tokio::sync::mpsc::channel(1024).0,
            semantic_event_rx: std::sync::Mutex::new(None),
        }),
    }
}

fn cleanup(state: &AppState) {
    let data_dir = state.inner.config.persistence.data_dir.clone();
    let _ = std::fs::remove_dir_all(&data_dir);
}

/// Integration test: create a real SSH group and verify DB storage.
/// Uses `true` as the command (exits immediately) to avoid hanging.
#[tokio::test]
async fn create_session_in_ssh_group_stores_originals_in_db() {
    let state = test_state();
    let group = state
        .inner
        .db
        .create_group("remote", "~/projects", None, Some("devbox"))
        .unwrap();
    let group_id = uuid::Uuid::parse_str(&group.id).unwrap();

    // Use `true` (exits immediately) to test without hanging
    let session = state
        .create_session(group_id, None, Some("true".to_string()), None, None)
        .unwrap();

    // `true` doesn't start with "ssh ", so no transformation
    // DB should store the original values
    let db_sessions = state.inner.db.list_sessions().unwrap();
    assert_eq!(db_sessions.len(), 1);
    assert_eq!(db_sessions[0].shell, "true");
    assert_eq!(db_sessions[0].cwd, "~/projects");

    // Cleanup
    state.kill_session(session.id).ok();
    cleanup(&state);
}

#[tokio::test]
async fn create_local_session_uses_group_cwd() {
    let state = test_state();
    let group = state
        .inner
        .db
        .create_group("local", "~", None, None)
        .unwrap();
    let group_id = uuid::Uuid::parse_str(&group.id).unwrap();

    let session = state
        .create_session(group_id, None, Some("true".to_string()), None, None)
        .unwrap();

    let db_sessions = state.inner.db.list_sessions().unwrap();
    assert_eq!(db_sessions[0].cwd, "~");
    assert_eq!(db_sessions[0].shell, "true");

    state.kill_session(session.id).ok();
    cleanup(&state);
}
