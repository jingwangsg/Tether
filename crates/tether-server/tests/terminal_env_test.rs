use std::os::unix::fs::PermissionsExt;
use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration;

use dashmap::DashMap;
use tempfile::tempdir;
use uuid::Uuid;

use tether_server::config::{PersistenceSection, ServerConfig, ServerSection, TerminalSection};
use tether_server::persistence::Store;
use tether_server::remote::manager::RemoteManager;
use tether_server::state::{AppState, AppStateInner};

static ENV_MUTEX: Mutex<()> = Mutex::new(());

fn test_state() -> AppState {
    test_state_with_shell("")
}

fn test_state_with_shell(default_shell: &str) -> AppState {
    let data_dir = std::env::temp_dir()
        .join(format!("tether-terminal-env-test-{}", Uuid::new_v4()))
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
        terminal: TerminalSection {
            default_shell: default_shell.to_string(),
            ..TerminalSection::default()
        },
    };
    config.materialize_terminal_runtime().unwrap();

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
            remote_manager: RemoteManager::new(),
            ssh_fg: DashMap::new(),
            ssh_live_sessions: DashMap::new(),
            attention_trackers: DashMap::new(),
        }),
    }
}

fn cleanup(state: &AppState) {
    let _ = std::fs::remove_dir_all(&state.inner.config.persistence.data_dir);
}

#[tokio::test]
async fn local_session_reports_ghostty_terminal_identity() {
    let _guard = ENV_MUTEX.lock().unwrap();
    let home = tempdir().unwrap();
    let old_home = std::env::var_os("HOME");
    std::env::set_var("HOME", home.path());

    let state = test_state();
    let group = state.inner.db.create_group("g", "~", None, None).unwrap();
    let temp = tempdir().unwrap();
    let script_path = temp.path().join("print-env.sh");
    std::fs::write(
        &script_path,
        "#!/bin/sh\nprintf '%s|%s|%s|%s' \"$TERM\" \"$TERMINFO\" \"$COLORTERM\" \"$TERM_PROGRAM\"\n",
    )
    .unwrap();
    std::fs::set_permissions(&script_path, std::fs::Permissions::from_mode(0o755)).unwrap();

    let session = state
        .create_session(
            Uuid::parse_str(&group.id).unwrap(),
            Some("env".to_string()),
            Some(script_path.display().to_string()),
            None,
            None,
        )
        .unwrap();

    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let output = loop {
        let output = String::from_utf8_lossy(&session.get_scrollback_snapshot()).into_owned();
        if output.contains("xterm-ghostty|") || tokio::time::Instant::now() >= deadline {
            break output;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    };
    let line = output
        .lines()
        .find(|line| line.contains("xterm-ghostty|"))
        .expect("expected TERM line in PTY output");
    let parts: Vec<&str> = line.split('|').collect();
    assert_eq!(parts.len(), 4, "unexpected env output: {line}");
    assert_eq!(parts[0], "xterm-ghostty");
    assert_eq!(parts[2], "truecolor");
    assert_eq!(parts[3], "ghostty");
    assert!(
        parts[1].ends_with("/runtime/terminfo"),
        "unexpected TERMINFO path: {}",
        parts[1]
    );
    assert!(std::path::Path::new(parts[1]).exists());

    cleanup(&state);
    if let Some(home) = old_home {
        std::env::set_var("HOME", home);
    } else {
        std::env::remove_var("HOME");
    }
}

#[tokio::test]
async fn local_session_clear_succeeds_after_terminfo_env_is_unset() {
    let _guard = ENV_MUTEX.lock().unwrap();
    let home = tempdir().unwrap();
    let old_home = std::env::var_os("HOME");
    std::env::set_var("HOME", home.path());

    let state = test_state();
    let group = state.inner.db.create_group("g", "~", None, None).unwrap();
    let temp = tempdir().unwrap();
    let script_path = temp.path().join("clear-without-terminfo.sh");
    std::fs::write(
        &script_path,
        "#!/bin/sh\nunset TERMINFO\nclear >/dev/null 2>&1\nstatus=$?\nprintf '%s|%s|%s\\n' \"$TERM\" \"${TERMINFO:-unset}\" \"$status\"\n",
    )
    .unwrap();
    std::fs::set_permissions(&script_path, std::fs::Permissions::from_mode(0o755)).unwrap();

    let user_terminfo = home.path().join(".terminfo/78/xterm-ghostty");
    assert!(
        user_terminfo.exists(),
        "expected installed terminfo at {:?}",
        user_terminfo
    );

    let session = state
        .create_session(
            Uuid::parse_str(&group.id).unwrap(),
            Some("clear".to_string()),
            Some(script_path.display().to_string()),
            None,
            None,
        )
        .unwrap();

    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let output = loop {
        let output = String::from_utf8_lossy(&session.get_scrollback_snapshot()).into_owned();
        if output.contains("xterm-ghostty|unset|") || tokio::time::Instant::now() >= deadline {
            break output;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    };
    let line = output
        .lines()
        .find(|line| line.contains("xterm-ghostty|unset|"))
        .expect("expected clear result line in PTY output");
    let parts: Vec<&str> = line.split('|').collect();
    assert_eq!(parts.len(), 3, "unexpected clear output: {line}");
    assert_eq!(parts[0], "xterm-ghostty");
    assert_eq!(parts[1], "unset");
    assert_eq!(parts[2], "0");

    cleanup(&state);
    if let Some(home) = old_home {
        std::env::set_var("HOME", home);
    } else {
        std::env::remove_var("HOME");
    }
}

#[tokio::test]
async fn default_bash_shell_wrapper_emits_lifecycle_markers_with_prompt_command_array() {
    let _guard = ENV_MUTEX.lock().unwrap();
    let home = tempdir().unwrap();
    let old_home = std::env::var_os("HOME");
    std::env::set_var("HOME", home.path());
    std::fs::write(
        home.path().join(".bashrc"),
        "PROMPT_COMMAND=('true' 'true')\n",
    )
    .unwrap();

    let state = test_state_with_shell("/bin/bash");
    let group = state.inner.db.create_group("g", "~", None, None).unwrap();
    let session = state
        .create_session(
            Uuid::parse_str(&group.id).unwrap(),
            Some("bash".to_string()),
            None,
            None,
            None,
        )
        .unwrap();

    let prompt_deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        if session.compute_tool_state() == Some(tether_server::pty::session::ToolState::Waiting) {
            break;
        }
        let snapshot = String::from_utf8_lossy(&session.get_scrollback_snapshot()).into_owned();
        assert!(
            tokio::time::Instant::now() < prompt_deadline,
            "bash wrapper never reached prompt state; output so far: {snapshot:?}"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    session.write_input(b"sleep 1\n").unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(
        session.compute_tool_state(),
        Some(tether_server::pty::session::ToolState::Running),
        "bash wrapper should mark command execution as running"
    );

    let finish_deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    loop {
        if session.compute_tool_state() == Some(tether_server::pty::session::ToolState::Waiting) {
            break;
        }
        assert!(
            tokio::time::Instant::now() < finish_deadline,
            "bash wrapper never returned to waiting after command completion"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    session.kill();
    cleanup(&state);
    if let Some(home) = old_home {
        std::env::set_var("HOME", home);
    } else {
        std::env::remove_var("HOME");
    }
}
