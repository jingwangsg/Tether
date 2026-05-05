use std::os::unix::fs::PermissionsExt;
use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration;

use dashmap::DashMap;
use tempfile::tempdir;
use uuid::Uuid;

use tether_server::config::{PersistenceSection, ServerConfig, ServerSection, TerminalSection};
use tether_server::persistence::Store;
use tether_server::pty::session::PtySession;
use tether_server::remote::manager::RemoteManager;
use tether_server::state::{AppState, AppStateInner};

static ENV_MUTEX: Mutex<()> = Mutex::new(());

fn test_state() -> AppState {
    test_state_with_shell("")
}

fn test_state_with_shell(default_shell: &str) -> AppState {
    test_state_with_shell_and_semantic_rx(default_shell).0
}

fn test_state_with_shell_and_semantic_rx(
    default_shell: &str,
) -> (AppState, tokio::sync::mpsc::Receiver<Uuid>) {
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
    let (semantic_event_tx, semantic_event_rx) = tokio::sync::mpsc::channel(1024);

    let state = AppState {
        inner: Arc::new(AppStateInner {
            config,
            sessions: DashMap::new(),
            db,
            shutdown_tx,
            status_tx,
            remote_manager: RemoteManager::new(),
            ssh_fg: DashMap::new(),
            ssh_live_sessions: DashMap::new(),
            semantic_event_tx,
            semantic_event_rx: std::sync::Mutex::new(None),
        }),
    };
    (state, semantic_event_rx)
}

fn init_test_tracing() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter("tether_server::pty=debug,tool-state=debug")
        .with_test_writer()
        .try_init();
}

fn cleanup(state: &AppState) {
    let _ = std::fs::remove_dir_all(&state.inner.config.persistence.data_dir);
}

fn scrollback_snapshot(session: &Arc<PtySession>) -> String {
    let bytes = session
        .scrollback
        .lock()
        .ok()
        .and_then(|scrollback| scrollback.read_disk(0, 1_048_576).ok())
        .unwrap_or_default();
    String::from_utf8_lossy(&bytes).into_owned()
}

async fn wait_for_file_contains(path: &std::path::Path, needle: &str) -> String {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        if let Ok(contents) = std::fs::read_to_string(path) {
            if contents.contains(needle) {
                return contents;
            }
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "file {:?} never contained {:?}",
            path,
            needle
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

async fn wait_for_scrollback_contains(session: &Arc<PtySession>, needle: &str) -> String {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let snapshot = scrollback_snapshot(session);
        if snapshot.contains(needle) {
            return snapshot;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "scrollback never contained {:?}; latest snapshot: {:?}",
            needle,
            snapshot
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

async fn wait_for_shell_integration(session: &Arc<PtySession>) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        if session.has_shell_integration() {
            return;
        }
        let snapshot = scrollback_snapshot(session);
        assert!(
            tokio::time::Instant::now() < deadline,
            "shell integration never became active; latest snapshot: {:?}",
            snapshot
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

async fn attention_eventually(session: &Arc<PtySession>) -> Result<(), String> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    loop {
        let fg = session.get_foreground();
        if fg.attention_seq > fg.attention_ack_seq {
            return Ok(());
        }
        let snapshot = scrollback_snapshot(session);
        if tokio::time::Instant::now() >= deadline {
            return Err(format!(
                "session never became attention; latest foreground: {:?}; latest snapshot: {:?}",
                fg, snapshot
            ));
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[test]
fn materialize_terminal_runtime_writes_agent_bundle_files() {
    let temp = tempfile::tempdir().unwrap();
    let config = ServerConfig {
        persistence: PersistenceSection {
            data_dir: temp.path().display().to_string(),
        },
        ..ServerConfig::default()
    };

    config.materialize_terminal_runtime().unwrap();

    assert!(config.agent_notify_path().exists());
    assert!(config.claude_wrapper_path().exists());
    assert!(config.terminal_notifier_shim_path().exists());
    assert!(config.nested_ssh_wrapper_path().exists());
    assert!(config.shadow_codex_home_dir().join("hooks.json").exists());
    assert!(config.shadow_codex_home_dir().join("config.toml").exists());
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
        let output = scrollback_snapshot(&session);
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
        let output = scrollback_snapshot(&session);
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

    // Wait for the session to report shell integration (from OSC 133 markers)
    let prompt_deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        if session.has_shell_integration() {
            break;
        }
        let snapshot = scrollback_snapshot(&session);
        assert!(
            tokio::time::Instant::now() < prompt_deadline,
            "bash wrapper never detected shell integration; output so far: {snapshot:?}"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    assert!(
        session.has_shell_integration(),
        "bash wrapper should emit OSC 133 markers enabling shell integration"
    );

    session.kill();
    cleanup(&state);
    if let Some(home) = old_home {
        std::env::set_var("HOME", home);
    } else {
        std::env::remove_var("HOME");
    }
}

#[tokio::test]
async fn local_session_claude_wrapper_injects_hooks_and_prefers_runtime_bundle() {
    let _guard = ENV_MUTEX.lock().unwrap();
    let home = tempdir().unwrap();
    let old_home = std::env::var_os("HOME");
    let old_path = std::env::var_os("PATH");
    std::env::set_var("HOME", home.path());

    let state = test_state_with_shell("/bin/bash");
    let group = state.inner.db.create_group("g", "~", None, None).unwrap();

    let temp = tempdir().unwrap();
    let real_dir = temp.path().join("real-bin");
    std::fs::create_dir_all(&real_dir).unwrap();
    let argv_log = temp.path().join("claude-argv.log");
    std::fs::write(
        real_dir.join("claude"),
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\n",
            argv_log.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(
        real_dir.join("claude"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();

    let path_with_fake = match &old_path {
        Some(path) => format!("{}:{}", real_dir.display(), path.to_string_lossy()),
        None => real_dir.display().to_string(),
    };
    std::env::set_var("PATH", path_with_fake);

    let session = state
        .create_session(
            Uuid::parse_str(&group.id).unwrap(),
            Some("shell".to_string()),
            None,
            None,
            None,
        )
        .unwrap();

    wait_for_shell_integration(&session).await;
    session.write_input(b"claude hello\n").unwrap();

    let argv = wait_for_file_contains(&argv_log, "--settings").await;
    assert!(argv.contains("hello"), "expected original arg in {argv:?}");
    assert!(
        argv.contains("--settings"),
        "expected injected settings in {argv:?}"
    );

    session.kill();
    cleanup(&state);
    if let Some(home) = old_home {
        std::env::set_var("HOME", home);
    } else {
        std::env::remove_var("HOME");
    }
    if let Some(path) = old_path {
        std::env::set_var("PATH", path);
    } else {
        std::env::remove_var("PATH");
    }
}

#[tokio::test]
async fn local_session_terminal_notifier_shim_emits_osc777() {
    let _guard = ENV_MUTEX.lock().unwrap();
    let home = tempdir().unwrap();
    let old_home = std::env::var_os("HOME");
    let old_path = std::env::var_os("PATH");
    std::env::set_var("HOME", home.path());

    let state = test_state_with_shell("/bin/bash");
    let group = state.inner.db.create_group("g", "~", None, None).unwrap();

    let temp = tempdir().unwrap();
    let real_dir = temp.path().join("real-bin");
    std::fs::create_dir_all(&real_dir).unwrap();
    std::fs::write(
        real_dir.join("terminal-notifier"),
        "#!/bin/sh\nprintf 'real-terminal-notifier\\n'\n",
    )
    .unwrap();
    std::fs::set_permissions(
        real_dir.join("terminal-notifier"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();

    let path_with_fake = match &old_path {
        Some(path) => format!("{}:{}", real_dir.display(), path.to_string_lossy()),
        None => real_dir.display().to_string(),
    };
    std::env::set_var("PATH", path_with_fake);

    let session = state
        .create_session(
            Uuid::parse_str(&group.id).unwrap(),
            Some("shell".to_string()),
            None,
            None,
            None,
        )
        .unwrap();

    wait_for_shell_integration(&session).await;
    session
        .write_input(b"terminal-notifier -title 'Codex' -message 'needs input'\n")
        .unwrap();

    let output = wait_for_scrollback_contains(&session, "]777;notify;Codex;needs input").await;
    assert!(
        output.contains("]777;notify;Codex;needs input"),
        "expected OSC 777 reminder in {output:?}"
    );

    session.kill();
    cleanup(&state);
    if let Some(home) = old_home {
        std::env::set_var("HOME", home);
    } else {
        std::env::remove_var("HOME");
    }
    if let Some(path) = old_path {
        std::env::set_var("PATH", path);
    } else {
        std::env::remove_var("PATH");
    }
}

#[tokio::test]
async fn local_session_agent_notify_osc777_marks_attention_without_runtime_threshold() {
    init_test_tracing();
    let _guard = ENV_MUTEX.lock().unwrap();
    let home = tempdir().unwrap();
    let old_home = std::env::var_os("HOME");
    std::env::set_var("HOME", home.path());

    let (state, semantic_event_rx) = test_state_with_shell_and_semantic_rx("/bin/bash");
    let monitor = tokio::spawn(tether_server::pty::process_monitor::run_process_monitor(
        state.clone(),
        semantic_event_rx,
    ));
    let group = state.inner.db.create_group("g", "~", None, None).unwrap();

    let session = state
        .create_session(
            Uuid::parse_str(&group.id).unwrap(),
            Some("shell".to_string()),
            None,
            None,
            None,
        )
        .unwrap();

    wait_for_shell_integration(&session).await;
    session
        .write_input(
            b"tether-agent-notify codex-running; printf '{\"last_assistant_message\":\"needs input\"}' | tether-agent-notify codex-waiting\n",
        )
        .unwrap();
    let output = wait_for_scrollback_contains(&session, "]777;notify;Codex;needs input").await;
    assert!(
        !output.contains("]2;✱ Codex") && !output.contains("]2;· Codex"),
        "agent notify should not override the agent's own OSC title: {output:?}"
    );
    let attention_result = attention_eventually(&session).await;

    monitor.abort();
    session.kill();
    cleanup(&state);
    if let Some(home) = old_home {
        std::env::set_var("HOME", home);
    } else {
        std::env::remove_var("HOME");
    }
    assert!(
        attention_result.is_ok(),
        "{}",
        attention_result.unwrap_err()
    );
}

#[tokio::test]
async fn nested_interactive_ssh_bootstraps_remote_agent_bundle() {
    let _guard = ENV_MUTEX.lock().unwrap();
    let home = tempdir().unwrap();
    let old_home = std::env::var_os("HOME");
    let old_path = std::env::var_os("PATH");
    std::env::set_var("HOME", home.path());

    let state = test_state_with_shell("/bin/bash");
    let group = state.inner.db.create_group("g", "~", None, None).unwrap();

    let temp = tempdir().unwrap();
    let fake_bin = temp.path().join("fake-bin");
    std::fs::create_dir_all(&fake_bin).unwrap();
    let ssh_log = temp.path().join("ssh.log");
    std::fs::write(
        fake_bin.join("ssh"),
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\n",
            ssh_log.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(fake_bin.join("ssh"), std::fs::Permissions::from_mode(0o755)).unwrap();

    let path_with_fake = match &old_path {
        Some(path) => format!("{}:{}", fake_bin.display(), path.to_string_lossy()),
        None => fake_bin.display().to_string(),
    };
    std::env::set_var("PATH", path_with_fake);

    let session = state
        .create_session(
            Uuid::parse_str(&group.id).unwrap(),
            Some("shell".to_string()),
            None,
            None,
            None,
        )
        .unwrap();

    wait_for_shell_integration(&session).await;
    session.write_input(b"ssh devbox\n").unwrap();

    let logged = wait_for_file_contains(&ssh_log, "devbox").await;
    assert!(
        logged.contains("TETHER_AGENT_NOTIFY_BIN"),
        "expected nested ssh bootstrap in {logged:?}"
    );
    assert!(
        logged.contains("CODEX_HOME"),
        "expected nested ssh to export CODEX_HOME in {logged:?}"
    );
    assert!(
        logged.contains("exec $SHELL -l"),
        "expected nested ssh to exec remote shell in {logged:?}"
    );

    session.kill();
    cleanup(&state);
    if let Some(home) = old_home {
        std::env::set_var("HOME", home);
    } else {
        std::env::remove_var("HOME");
    }
    if let Some(path) = old_path {
        std::env::set_var("PATH", path);
    } else {
        std::env::remove_var("PATH");
    }
}

#[tokio::test]
async fn nested_port_forward_ssh_bypasses_bootstrap() {
    let _guard = ENV_MUTEX.lock().unwrap();
    let home = tempdir().unwrap();
    let old_home = std::env::var_os("HOME");
    let old_path = std::env::var_os("PATH");
    std::env::set_var("HOME", home.path());

    let state = test_state_with_shell("/bin/bash");
    let group = state.inner.db.create_group("g", "~", None, None).unwrap();

    let temp = tempdir().unwrap();
    let fake_bin = temp.path().join("fake-bin");
    std::fs::create_dir_all(&fake_bin).unwrap();
    let ssh_log = temp.path().join("ssh.log");
    std::fs::write(
        fake_bin.join("ssh"),
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\n",
            ssh_log.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(fake_bin.join("ssh"), std::fs::Permissions::from_mode(0o755)).unwrap();

    let path_with_fake = match &old_path {
        Some(path) => format!("{}:{}", fake_bin.display(), path.to_string_lossy()),
        None => fake_bin.display().to_string(),
    };
    std::env::set_var("PATH", path_with_fake);

    let session = state
        .create_session(
            Uuid::parse_str(&group.id).unwrap(),
            Some("shell".to_string()),
            None,
            None,
            None,
        )
        .unwrap();

    wait_for_shell_integration(&session).await;
    session
        .write_input(b"ssh -N -L 9000:127.0.0.1:9000 devbox\n")
        .unwrap();

    let logged = wait_for_file_contains(&ssh_log, "9000:127.0.0.1:9000").await;
    assert!(
        !logged.contains("TETHER_AGENT_NOTIFY_BIN"),
        "did not expect nested ssh bootstrap in {logged:?}"
    );
    assert!(
        !logged.contains("CODEX_HOME"),
        "did not expect CODEX_HOME export in {logged:?}"
    );

    session.kill();
    cleanup(&state);
    if let Some(home) = old_home {
        std::env::set_var("HOME", home);
    } else {
        std::env::remove_var("HOME");
    }
    if let Some(path) = old_path {
        std::env::set_var("PATH", path);
    } else {
        std::env::remove_var("PATH");
    }
}
