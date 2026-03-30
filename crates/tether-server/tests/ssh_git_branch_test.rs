//! E2E tests for SSH session git branch detection.
//!
//! Tests the full pipeline:
//!   session creation → ssh_host/remote_cwd storage → detect_foreground → git_branch
//!
//! Covers:
//! - Local sessions detect git branch from local cwd
//! - SSH sessions route through remote detection (not local cwd)
//! - Unreachable SSH hosts fail gracefully (no hang, returns None)
//! - create_session correctly passes ssh_host/remote_cwd based on group config
//! - Non-SSH commands in SSH groups don't trigger remote detection
//! - Process monitor's detect_foreground returns correct SessionForeground

use std::sync::Arc;
use tether_server::pty::session::PtySession;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn temp_dir() -> String {
    let dir = std::env::temp_dir()
        .join(format!("tether-git-test-{}", Uuid::new_v4()))
        .to_string_lossy()
        .to_string();
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn write_script(dir: &str, content: &str) -> String {
    use std::os::unix::fs::PermissionsExt;
    let path = format!("{}/test.sh", dir);
    std::fs::write(&path, content).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

/// Create a minimal git repo in `dir` on the given branch.
/// Returns the branch name.
fn init_git_repo(dir: &str, branch: &str) -> String {
    let run = |args: &[&str]| {
        std::process::Command::new("git")
            .args(args)
            .current_dir(dir)
            .env("GIT_AUTHOR_NAME", "test")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "test")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .output()
            .expect("git command failed");
    };
    run(&["init", "-b", branch]);
    std::fs::write(format!("{}/f", dir), "x").unwrap();
    run(&["add", "."]);
    run(&["commit", "-m", "init"]);
    branch.to_string()
}

fn spawn_session(
    script: &str,
    cwd: &str,
    ssh_host: Option<String>,
    remote_cwd: Option<String>,
) -> Arc<PtySession> {
    let scrollback_dir = temp_dir();
    PtySession::spawn(
        Uuid::new_v4(),
        Uuid::new_v4(),
        "test",
        script,
        cwd,
        80,
        24,
        &scrollback_dir,
        64,
        1,
        ssh_host,
        remote_cwd,
    )
    .unwrap()
}

// ---------------------------------------------------------------------------
// AppState helpers (for create_session integration tests)
// ---------------------------------------------------------------------------

use dashmap::DashMap;
use tether_server::config::{PersistenceSection, ServerConfig, ServerSection, TerminalSection};
use tether_server::persistence::Store;
use tether_server::state::{AppState, AppStateInner};

fn test_state() -> AppState {
    let data_dir = std::env::temp_dir()
        .join(format!("tether-git-e2e-{}", Uuid::new_v4()))
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
    let (fg_tx, _) = tokio::sync::broadcast::channel(64);

    AppState {
        inner: Arc::new(AppStateInner {
            config,
            sessions: DashMap::new(),
            db,
            shutdown_tx,
            fg_tx,
        }),
    }
}

fn cleanup(state: &AppState) {
    let data_dir = state.inner.config.persistence.data_dir.clone();
    let _ = std::fs::remove_dir_all(&data_dir);
}

// ===========================================================================
// 1. Local git detection — session cwd IS a git repo
// ===========================================================================

#[tokio::test]
async fn local_session_in_git_repo_detects_branch() {
    let dir = temp_dir();
    let branch = init_git_repo(&dir, "feat-hello");
    let script = write_script(&dir, "#!/bin/sh\nsleep 30\n");

    let session = spawn_session(&script, &dir, None, None);

    let fg = session.detect_foreground();
    assert_eq!(
        fg.git_branch.as_deref(),
        Some(branch.as_str()),
        "local session should detect git branch from cwd"
    );

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn local_session_detects_custom_branch_name() {
    let dir = temp_dir();
    init_git_repo(&dir, "release/v2.0");
    let script = write_script(&dir, "#!/bin/sh\nsleep 30\n");

    let session = spawn_session(&script, &dir, None, None);

    let fg = session.detect_foreground();
    assert_eq!(
        fg.git_branch.as_deref(),
        Some("release/v2.0"),
        "should handle branch names with slashes"
    );

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

// ===========================================================================
// 2. Local session NOT in a git repo → None
// ===========================================================================

#[tokio::test]
async fn local_session_no_git_repo_returns_none() {
    let dir = temp_dir(); // no git init
    let script = write_script(&dir, "#!/bin/sh\nsleep 30\n");

    let session = spawn_session(&script, &dir, None, None);

    let fg = session.detect_foreground();
    assert_eq!(
        fg.git_branch, None,
        "non-git directory should return None"
    );

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

// ===========================================================================
// 3. SSH session routes through remote detection, NOT local cwd
// ===========================================================================

#[tokio::test]
async fn ssh_session_does_not_use_local_cwd_for_git() {
    // Create a real git repo and use it as the session's local cwd.
    // But set ssh_host — so detect_git_branch should go through the SSH path,
    // which will fail (host doesn't exist), returning None.
    // If it incorrectly used local cwd, it would return the branch name.
    let dir = temp_dir();
    init_git_repo(&dir, "main");
    let script = write_script(&dir, "#!/bin/sh\nsleep 30\n");

    let session = spawn_session(
        &script,
        &dir,
        Some("nonexistent-host-12345".to_string()),
        Some("~/projects".to_string()),
    );

    let fg = session.detect_foreground();
    assert_eq!(
        fg.git_branch, None,
        "SSH session should NOT detect branch from local cwd; \
         should route through remote detection which fails for fake host"
    );

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

// ===========================================================================
// 4. Unreachable SSH host fails gracefully
// ===========================================================================

#[tokio::test]
async fn ssh_unreachable_host_returns_none_without_panic() {
    let dir = temp_dir();
    let script = write_script(&dir, "#!/bin/sh\nsleep 30\n");

    // 192.0.2.1 = TEST-NET-1, guaranteed non-routable
    let session = spawn_session(
        &script,
        &dir,
        Some("192.0.2.1".to_string()),
        Some("~/work".to_string()),
    );

    // This should complete (not hang) thanks to ConnectTimeout=3
    let fg = session.detect_foreground();
    assert_eq!(
        fg.git_branch, None,
        "unreachable SSH host should return None"
    );

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn ssh_session_with_no_remote_cwd_defaults_to_home() {
    let dir = temp_dir();
    let script = write_script(&dir, "#!/bin/sh\nsleep 30\n");

    // ssh_host set, but remote_cwd is None → should default to ~
    let session = spawn_session(
        &script,
        &dir,
        Some("nonexistent-host-12345".to_string()),
        None,
    );

    let fg = session.detect_foreground();
    // Should not panic, should just return None (host unreachable)
    assert_eq!(fg.git_branch, None);

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

// ===========================================================================
// 5. detect_foreground returns both process and git_branch correctly
// ===========================================================================

#[tokio::test]
async fn detect_foreground_returns_branch_with_null_process() {
    let dir = temp_dir();
    init_git_repo(&dir, "develop");
    let script = write_script(&dir, "#!/bin/sh\nsleep 30\n");

    let session = spawn_session(&script, &dir, None, None);

    // Wait for script to start
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;

    let fg = session.detect_foreground();
    // Script is a plain shell script, not claude/codex → process should be None
    assert_eq!(fg.process, None, "plain script should have no detected process");
    assert_eq!(
        fg.git_branch.as_deref(),
        Some("develop"),
        "git branch should still be detected"
    );

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn detect_foreground_both_none_for_ssh_with_fake_host() {
    let dir = temp_dir();
    let script = write_script(&dir, "#!/bin/sh\nsleep 30\n");

    let session = spawn_session(
        &script,
        &dir,
        Some("nonexistent-host-12345".to_string()),
        Some("~/work".to_string()),
    );

    tokio::time::sleep(std::time::Duration::from_millis(300)).await;

    let fg = session.detect_foreground();
    assert_eq!(fg.process, None);
    assert_eq!(fg.git_branch, None);

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

// ===========================================================================
// 6. Integration: create_session with SSH group → correct routing
// ===========================================================================

#[tokio::test]
async fn create_session_ssh_group_routes_git_detection_remotely() {
    let state = test_state();

    // Create a git repo for the group's default_cwd so we can verify
    // the SSH path is taken (local detection would succeed, remote won't)
    let repo_dir = temp_dir();
    init_git_repo(&repo_dir, "main");

    // SSH group with default_cwd pointing to our git repo
    let group = state
        .inner
        .db
        .create_group("remote", &repo_dir, None, Some("nonexistent-host-12345"))
        .unwrap();
    let group_id = Uuid::parse_str(&group.id).unwrap();

    // "ssh nonexistent-host-12345" will fail to connect, but the session
    // will be created with ssh_host set. Using "true" avoids a hanging PTY.
    // Note: "true" doesn't start with "ssh ", so is_ssh = false.
    // Use the actual ssh command to trigger SSH routing.
    let session = state
        .create_session(
            group_id,
            None,
            Some("ssh nonexistent-host-12345".to_string()),
            None,
        )
        .unwrap();

    // The session's local cwd is ~ (from resolve_ssh_command), NOT repo_dir.
    // And ssh_host is set, so detect_git_branch goes through SSH path.
    // Since the host is fake, git_branch should be None.
    let fg = session.detect_foreground();
    assert_eq!(
        fg.git_branch, None,
        "SSH session should use remote detection (which fails for fake host), \
         not local detection from the repo dir"
    );

    state.kill_session(session.id).ok();
    cleanup(&state);
    let _ = std::fs::remove_dir_all(&repo_dir);
}

#[tokio::test]
async fn create_session_local_group_detects_git_locally() {
    let state = test_state();

    let repo_dir = temp_dir();
    init_git_repo(&repo_dir, "feature-x");

    let group = state
        .inner
        .db
        .create_group("local", &repo_dir, None, None)
        .unwrap();
    let group_id = Uuid::parse_str(&group.id).unwrap();

    // Use "true" which exits immediately — but detect_git_branch still works
    // because it just runs `git` on the cwd, doesn't need a live PTY.
    let session = state
        .create_session(group_id, None, Some("true".to_string()), None)
        .unwrap();

    let fg = session.detect_foreground();
    assert_eq!(
        fg.git_branch.as_deref(),
        Some("feature-x"),
        "local session should detect branch from group's default_cwd"
    );

    state.kill_session(session.id).ok();
    cleanup(&state);
    let _ = std::fs::remove_dir_all(&repo_dir);
}

#[tokio::test]
async fn create_session_non_ssh_command_in_ssh_group_uses_local_detection() {
    let state = test_state();

    let repo_dir = temp_dir();
    init_git_repo(&repo_dir, "main");

    // SSH group, but command is NOT "ssh ..."
    let group = state
        .inner
        .db
        .create_group("remote", &repo_dir, None, Some("devbox"))
        .unwrap();
    let group_id = Uuid::parse_str(&group.id).unwrap();

    // "true" doesn't start with "ssh ", so is_ssh=false, no SSH routing
    let session = state
        .create_session(group_id, None, Some("true".to_string()), None)
        .unwrap();

    let fg = session.detect_foreground();
    assert_eq!(
        fg.git_branch.as_deref(),
        Some("main"),
        "non-SSH command should use local git detection even in SSH group"
    );

    state.kill_session(session.id).ok();
    cleanup(&state);
    let _ = std::fs::remove_dir_all(&repo_dir);
}

// ===========================================================================
// 7. Multiple sessions: verify independent git detection
// ===========================================================================

#[tokio::test]
async fn multiple_sessions_independent_git_detection() {
    let state = test_state();

    // Repo A on branch "alpha"
    let repo_a = temp_dir();
    init_git_repo(&repo_a, "alpha");
    let group_a = state
        .inner
        .db
        .create_group("local-a", &repo_a, None, None)
        .unwrap();
    let gid_a = Uuid::parse_str(&group_a.id).unwrap();

    // Repo B on branch "beta"
    let repo_b = temp_dir();
    init_git_repo(&repo_b, "beta");
    let group_b = state
        .inner
        .db
        .create_group("local-b", &repo_b, None, None)
        .unwrap();
    let gid_b = Uuid::parse_str(&group_b.id).unwrap();

    // SSH group — should fail remote detection
    let group_ssh = state
        .inner
        .db
        .create_group("remote", "~/work", None, Some("fake-host"))
        .unwrap();
    let gid_ssh = Uuid::parse_str(&group_ssh.id).unwrap();

    let s_a = state
        .create_session(gid_a, None, Some("true".to_string()), None)
        .unwrap();
    let s_b = state
        .create_session(gid_b, None, Some("true".to_string()), None)
        .unwrap();
    let s_ssh = state
        .create_session(gid_ssh, None, Some("ssh fake-host".to_string()), None)
        .unwrap();

    let fg_a = s_a.detect_foreground();
    let fg_b = s_b.detect_foreground();
    let fg_ssh = s_ssh.detect_foreground();

    assert_eq!(fg_a.git_branch.as_deref(), Some("alpha"));
    assert_eq!(fg_b.git_branch.as_deref(), Some("beta"));
    assert_eq!(fg_ssh.git_branch, None, "SSH to fake host should be None");

    state.kill_session(s_a.id).ok();
    state.kill_session(s_b.id).ok();
    state.kill_session(s_ssh.id).ok();
    cleanup(&state);
    let _ = std::fs::remove_dir_all(&repo_a);
    let _ = std::fs::remove_dir_all(&repo_b);
}

// ===========================================================================
// 8. REST API returns git_branch for local sessions
// ===========================================================================

#[tokio::test]
async fn list_sessions_api_includes_git_branch() {
    let state = test_state();

    let repo_dir = temp_dir();
    init_git_repo(&repo_dir, "api-test-branch");

    let group = state
        .inner
        .db
        .create_group("local", &repo_dir, None, None)
        .unwrap();
    let group_id = Uuid::parse_str(&group.id).unwrap();

    let session = state
        .create_session(group_id, None, Some("true".to_string()), None)
        .unwrap();

    // Simulate what the process monitor does: detect and store foreground
    let fg = session.detect_foreground();
    *session.foreground.lock().unwrap() = fg;

    // Now simulate what list_sessions API does: read foreground from session
    let stored_fg = session.get_foreground();
    assert_eq!(
        stored_fg.git_branch.as_deref(),
        Some("api-test-branch"),
        "stored foreground should contain git branch for API response"
    );

    state.kill_session(session.id).ok();
    cleanup(&state);
    let _ = std::fs::remove_dir_all(&repo_dir);
}

// ===========================================================================
// 9. Edge case: git repo in detached HEAD state
// ===========================================================================

#[tokio::test]
async fn detached_head_returns_none() {
    let dir = temp_dir();
    init_git_repo(&dir, "main");

    // Detach HEAD
    std::process::Command::new("git")
        .args(["checkout", "--detach"])
        .current_dir(&dir)
        .output()
        .unwrap();

    let script = write_script(&dir, "#!/bin/sh\nsleep 30\n");
    let session = spawn_session(&script, &dir, None, None);

    let fg = session.detect_foreground();
    // "HEAD" is filtered out by detect_git_branch
    assert_eq!(
        fg.git_branch, None,
        "detached HEAD should return None"
    );

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}

// ===========================================================================
// 10. Git branch detection in subdirectory of repo
// ===========================================================================

#[tokio::test]
async fn git_detection_works_from_repo_subdirectory() {
    let dir = temp_dir();
    init_git_repo(&dir, "sub-test");

    let sub_dir = format!("{}/deep/nested/dir", dir);
    std::fs::create_dir_all(&sub_dir).unwrap();

    let script = write_script(&dir, "#!/bin/sh\nsleep 30\n");
    // Session cwd is a subdirectory of the repo
    let session = spawn_session(&script, &sub_dir, None, None);

    let fg = session.detect_foreground();
    assert_eq!(
        fg.git_branch.as_deref(),
        Some("sub-test"),
        "should detect branch from subdirectory of git repo"
    );

    session.kill();
    let _ = std::fs::remove_dir_all(&dir);
}
