use std::sync::Arc;
use std::time::Duration;
use tether_server::pty::session::{PtySession, PtyTerminalEnv};
use uuid::Uuid;

/// Create a temp directory for scrollback storage.
fn temp_dir() -> String {
    let dir = std::env::temp_dir()
        .join(format!("tether-osc-test-{}", Uuid::new_v4()))
        .to_string_lossy()
        .to_string();
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Write a shell script to the temp dir and return its path.
/// Using a script file (no spaces in path) avoids the login-shell wrapper
/// in PtySession::spawn, so we get clean output without .zshrc interference.
fn write_script(dir: &str, content: &str) -> String {
    use std::os::unix::fs::PermissionsExt;
    let path = format!("{}/test.sh", dir);
    std::fs::write(&path, content).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn write_named_script(dir: &str, name: &str, content: &str) -> String {
    use std::os::unix::fs::PermissionsExt;
    let path = format!("{}/{}", dir, name);
    std::fs::write(&path, content).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn spawn_session(script: &str, dir: &str) -> Arc<PtySession> {
    let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
    PtySession::spawn(
        Uuid::new_v4(),
        Uuid::new_v4(),
        "test",
        script,
        "/tmp",
        80,
        24,
        dir,
        64,
        1,
        PtyTerminalEnv::default(),
        tx,
    )
    .unwrap()
}

/// Wait for PTY output to arrive, then give a small buffer for OSC parsing.
async fn wait_for_output(session: &PtySession) {
    let mut rx = session.output_tx.subscribe();
    // Wait for first output chunk (the printf output)
    let _ = tokio::time::timeout(Duration::from_secs(5), rx.recv()).await;
    // Small delay to ensure any follow-up chunks are also processed
    tokio::time::sleep(Duration::from_millis(200)).await;
}

/// Poll detect_foreground until it matches expected, or timeout.
async fn poll_foreground(session: &PtySession, expected: Option<&str>) -> Option<String> {
    let start = std::time::Instant::now();
    loop {
        let fg = session.detect_foreground();
        if fg.process.as_deref() == expected {
            return fg.process;
        }
        if start.elapsed() > Duration::from_secs(5) {
            return fg.process;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

// --- Integration tests ---

#[tokio::test]
async fn test_osc_detects_claude_code() {
    let dir = temp_dir();
    let script = write_script(
        &dir,
        "#!/bin/sh\nprintf '\\033]0;Claude Code\\007'\nsleep 30\n",
    );
    let session = spawn_session(&script, &dir);

    let result = poll_foreground(&session, Some("claude")).await;
    assert_eq!(result, Some("claude".to_string()));

    // osc_title should be populated from the OSC sequence
    let fg = session.detect_foreground();
    assert_eq!(
        fg.osc_title,
        Some("Claude Code".to_string()),
        "detect_foreground should include the raw OSC title"
    );

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn test_osc_detects_codex() {
    let dir = temp_dir();
    let script = write_script(
        &dir,
        "#!/bin/sh\nprintf '\\033]0;Codex CLI\\007'\nsleep 30\n",
    );
    let session = spawn_session(&script, &dir);

    let result = poll_foreground(&session, Some("codex")).await;
    assert_eq!(result, Some("codex".to_string()));

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn test_osc_no_false_positive() {
    let dir = temp_dir();
    let script = write_script(
        &dir,
        "#!/bin/sh\nprintf '\\033]0;vim - main.rs\\007'\nsleep 30\n",
    );
    let session = spawn_session(&script, &dir);

    wait_for_output(&session).await;
    let fg = session.detect_foreground();
    assert_eq!(
        fg.process, None,
        "should not detect a tool from unrelated title"
    );

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn test_osc_st_terminator() {
    let dir = temp_dir();
    // ST terminator: \033\\ (ESC + backslash)
    let script = write_script(
        &dir,
        "#!/bin/sh\nprintf '\\033]2;Claude Code\\033\\\\'\nsleep 30\n",
    );
    let session = spawn_session(&script, &dir);

    let result = poll_foreground(&session, Some("claude")).await;
    assert_eq!(result, Some("claude".to_string()));

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn test_osc_case_insensitive() {
    let dir = temp_dir();
    let script = write_script(
        &dir,
        "#!/bin/sh\nprintf '\\033]0;CLAUDE CODE v2\\007'\nsleep 30\n",
    );
    let session = spawn_session(&script, &dir);

    let result = poll_foreground(&session, Some("claude")).await;
    assert_eq!(result, Some("claude".to_string()));

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn test_osc_title_updated_on_change() {
    let dir = temp_dir();
    // First set a non-tool title, then after a delay set Claude Code
    let script = write_script(
        &dir,
        "#!/bin/sh\nprintf '\\033]0;vim\\007'\nsleep 1\nprintf '\\033]0;Claude Code\\007'\nsleep 30\n",
    );
    let session = spawn_session(&script, &dir);

    // Should eventually detect claude after the second printf
    let result = poll_foreground(&session, Some("claude")).await;
    assert_eq!(result, Some("claude".to_string()));

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

// --- Sticky OSC title tests ---

#[tokio::test]
async fn test_sticky_osc_survives_empty_title() {
    let dir = temp_dir();
    // Set "claude" title, then clear it (empty). Sticky should persist.
    let script = write_script(
        &dir,
        "#!/bin/sh\nprintf '\\033]0;claude\\007'\nsleep 0.3\nprintf '\\033]0;\\007'\nsleep 30\n",
    );
    let session = spawn_session(&script, &dir);

    // Wait for both OSC sequences to be processed
    let result = poll_foreground(&session, Some("claude")).await;
    assert_eq!(result, Some("claude".to_string()));

    // Wait a bit more for the empty title to arrive, then re-check
    tokio::time::sleep(Duration::from_millis(800)).await;
    let fg = session.detect_foreground();
    assert_eq!(
        fg.process,
        Some("claude".to_string()),
        "sticky should persist after empty title"
    );

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn test_sticky_osc_cleared_by_shell_title() {
    let dir = temp_dir();
    // Set "claude" title, then set a non-tool title (simulating shell prompt reclaiming title).
    let script = write_script(
        &dir,
        "#!/bin/sh\nprintf '\\033]0;claude\\007'\nsleep 0.3\nprintf '\\033]0;user@host: ~/dir\\007'\nsleep 30\n",
    );
    let session = spawn_session(&script, &dir);

    // First detect claude
    let result = poll_foreground(&session, Some("claude")).await;
    assert_eq!(result, Some("claude".to_string()));

    // Then wait for the shell title to clear the sticky detection
    let result = poll_foreground(&session, None).await;
    assert_eq!(result, None, "sticky should be cleared by non-tool title");

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

// --- Alternate screen + output detection tests ---

#[tokio::test]
async fn test_output_detection_in_alt_screen() {
    let dir = temp_dir();
    // Enter alternate screen, print "Claude Code", sleep
    let script = write_script(
        &dir,
        "#!/bin/sh\nprintf '\\033[?1049h'\nsleep 0.1\nprintf 'Welcome to Claude Code v2.1\\n'\nsleep 30\n",
    );
    let session = spawn_session(&script, &dir);

    let result = poll_foreground(&session, Some("claude")).await;
    assert_eq!(result, Some("claude".to_string()));

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn test_output_detection_cleared_on_alt_screen_exit() {
    let dir = temp_dir();
    // Enter alt screen, print "Claude Code", exit alt screen
    let script = write_script(
        &dir,
        "#!/bin/sh\nprintf '\\033[?1049h'\nsleep 0.1\nprintf 'Claude Code v2\\n'\nsleep 0.5\nprintf '\\033[?1049l'\nsleep 30\n",
    );
    let session = spawn_session(&script, &dir);

    // First detect claude
    let result = poll_foreground(&session, Some("claude")).await;
    assert_eq!(result, Some("claude".to_string()));

    // Then wait for alt screen exit to clear detection
    let result = poll_foreground(&session, None).await;
    assert_eq!(
        result, None,
        "output detection should clear when alt screen exits"
    );

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn test_output_detection_no_false_positive_outside_alt_screen() {
    let dir = temp_dir();
    // Print "Claude Code" WITHOUT entering alternate screen — should NOT detect
    let script = write_script(&dir, "#!/bin/sh\nprintf 'Claude Code v2\\n'\nsleep 30\n");
    let session = spawn_session(&script, &dir);

    wait_for_output(&session).await;
    let fg = session.detect_foreground();
    assert_eq!(
        fg.process, None,
        "should not detect tool outside alternate screen"
    );

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn test_codex_child_process_survives_shell_title_reclaim() {
    let dir = temp_dir();
    let codex_path = write_named_script(&dir, "codex", "#!/bin/sh\nsleep 30\n");
    let script = write_script(
        &dir,
        &format!(
            "#!/bin/sh\nprintf '\\033]0;Codex CLI\\007'\n\"{codex_path}\" &\nchild=$!\nsleep 0.3\nprintf '\\033]0;user@host: ~/dir\\007'\nsleep 0.8\nwait \"$child\"\n"
        ),
    );
    let session = spawn_session(&script, &dir);

    let result = poll_foreground(&session, Some("codex")).await;
    assert_eq!(result, Some("codex".to_string()));

    tokio::time::sleep(Duration::from_millis(900)).await;
    let fg = session.detect_foreground();
    assert_eq!(
        fg.process,
        Some("codex".to_string()),
        "should keep detecting codex while the wrapper keeps a codex child alive after reclaiming the shell title"
    );

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}
