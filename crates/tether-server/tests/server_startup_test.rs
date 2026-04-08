use std::sync::Arc;
use std::time::Duration;

use axum::{routing::get, Json, Router};
use dashmap::DashMap;
use tether_server::config::{PersistenceSection, ServerConfig, ServerSection, TerminalSection};
use tether_server::persistence::store::{GroupRow, SessionRow};
use tether_server::persistence::Store;
use tether_server::remote::manager::RemoteManager;
use tether_server::remote::sync::sync_remote_host;
use tether_server::server;
use tether_server::state::{AppState, AppStateInner};

fn test_state() -> AppState {
    let data_dir = std::env::temp_dir()
        .join(format!(
            "tether-server-startup-test-{}",
            uuid::Uuid::new_v4()
        ))
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
    let (semantic_event_tx, semantic_event_rx) = tokio::sync::mpsc::unbounded_channel();

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
            semantic_event_tx,
            semantic_event_rx: std::sync::Mutex::new(Some(semantic_event_rx)),
        }),
    }
}

fn cleanup_state(state: &AppState) {
    let data_dir = state.inner.config.persistence.data_dir.clone();
    let _ = std::fs::remove_dir_all(&data_dir);
}

async fn start_mock_remote(groups: Vec<GroupRow>, sessions: Vec<SessionRow>) -> u16 {
    #[derive(Clone)]
    struct MockState {
        groups: Arc<Vec<GroupRow>>,
        sessions: Arc<Vec<SessionRow>>,
    }

    async fn list_groups(
        axum::extract::State(state): axum::extract::State<MockState>,
    ) -> Json<Vec<GroupRow>> {
        Json((*state.groups).clone())
    }

    async fn list_sessions(
        axum::extract::State(state): axum::extract::State<MockState>,
    ) -> Json<Vec<SessionRow>> {
        Json((*state.sessions).clone())
    }

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let app = Router::new()
        .route("/api/groups", get(list_groups))
        .route("/api/sessions", get(list_sessions))
        .with_state(MockState {
            groups: Arc::new(groups),
            sessions: Arc::new(sessions),
        });
    tokio::spawn(async move {
        axum::serve(listener, app).await.ok();
    });
    tokio::time::sleep(Duration::from_millis(10)).await;
    port
}

#[tokio::test]
async fn server_startup_deletes_local_sessions_and_remote_mirrors() {
    let state = test_state();
    state
        .inner
        .db
        .mark_shared_remote_model_initialized()
        .unwrap();

    let local_group = state
        .inner
        .db
        .create_group("local", "~", None, None)
        .unwrap();
    let remote_group = state
        .inner
        .db
        .create_group("remote", "~", None, Some("shared-host"))
        .unwrap();

    state
        .inner
        .db
        .create_session(
            "local-session",
            &local_group.id,
            "local",
            "/bin/sh",
            "~",
            None,
        )
        .unwrap();
    let local_scrollback_dir = format!(
        "{}/sessions/local-session",
        state.inner.config.persistence.data_dir
    );
    std::fs::create_dir_all(&local_scrollback_dir).unwrap();
    std::fs::write(
        format!("{local_scrollback_dir}/scrollback.raw"),
        b"local-history",
    )
    .unwrap();
    state
        .inner
        .db
        .create_session(
            "remote-session",
            &remote_group.id,
            "remote",
            "/bin/bash",
            "/srv/app",
            None,
        )
        .unwrap();

    let server_task = tokio::spawn(server::run(state.clone(), true));

    for _ in 0..20 {
        if state
            .inner
            .db
            .get_session("local-session")
            .unwrap()
            .is_none()
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    assert!(
        state
            .inner
            .db
            .get_session("local-session")
            .unwrap()
            .is_none(),
        "local sessions should be deleted on server restart"
    );
    assert!(
        !std::path::Path::new(&local_scrollback_dir).exists(),
        "local session scrollback should be deleted on server restart"
    );
    // Remote mirrors are now deleted on startup (remote server is source of truth).
    // They are rebuilt when SSH tunnels reconnect via sync_remote_host.
    assert!(
        state
            .inner
            .db
            .get_session("remote-session")
            .unwrap()
            .is_none(),
        "remote mirrored sessions should be deleted on server restart"
    );
    assert!(
        state
            .inner
            .db
            .get_group(&remote_group.id)
            .unwrap()
            .is_none(),
        "remote mirrored groups should be deleted on server restart"
    );

    server_task.abort();
    let _ = server_task.await;
    cleanup_state(&state);
}

#[tokio::test]
async fn server_startup_clears_legacy_ssh_mirrors_and_sync_rebuilds_shared_state() {
    let state = test_state();

    let local_group = state
        .inner
        .db
        .create_group("local", "~", None, None)
        .unwrap();
    let legacy_remote_group = state
        .inner
        .db
        .create_group("legacy-remote", "~", None, Some("shared-host"))
        .unwrap();

    state
        .inner
        .db
        .create_session(
            "local-session",
            &local_group.id,
            "local",
            "/bin/sh",
            "~",
            None,
        )
        .unwrap();
    state
        .inner
        .db
        .create_session(
            "legacy-remote-session",
            &legacy_remote_group.id,
            "legacy-remote",
            "/bin/bash",
            "/srv/legacy",
            None,
        )
        .unwrap();

    let server_task = tokio::spawn(server::run(state.clone(), true));

    for _ in 0..20 {
        if state
            .inner
            .db
            .get_group(&legacy_remote_group.id)
            .unwrap()
            .is_none()
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    assert!(
        state
            .inner
            .db
            .get_group(&legacy_remote_group.id)
            .unwrap()
            .is_none(),
        "legacy SSH-backed local group tree should be cleared on first shared-model startup"
    );
    assert!(
        state
            .inner
            .db
            .get_session("legacy-remote-session")
            .unwrap()
            .is_none(),
        "legacy SSH-backed local sessions should be cleared on first shared-model startup"
    );
    assert!(
        state
            .inner
            .db
            .get_session("local-session")
            .unwrap()
            .is_none(),
        "local sessions should also be deleted during the upgrade startup"
    );

    let authoritative_group = GroupRow {
        id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa".to_string(),
        name: "shared-remote".to_string(),
        default_cwd: "/srv/shared".to_string(),
        sort_order: 0,
        parent_id: None,
        ssh_host: None,
        created_at: "2024-01-01T00:00:00Z".to_string(),
        updated_at: "2024-01-01T00:00:00Z".to_string(),
    };
    let authoritative_session = SessionRow {
        id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb".to_string(),
        group_id: authoritative_group.id.clone(),
        name: "shared-session".to_string(),
        shell: "/bin/bash".to_string(),
        cols: 120,
        rows: 40,
        cwd: "/srv/shared".to_string(),
        created_at: "2024-01-01T00:00:00Z".to_string(),
        last_active: "2024-01-01T00:00:00Z".to_string(),
        sort_order: 0,
        is_alive: true,
        foreground_process: None,
        osc_title: None,
        local_group_id: None,
    };
    let remote_port = start_mock_remote(
        vec![authoritative_group.clone()],
        vec![authoritative_session.clone()],
    )
    .await;
    sync_remote_host(
        &state.inner.db,
        "shared-host",
        remote_port,
        &state.inner.ssh_fg,
        &state.inner.ssh_live_sessions,
        Some(&state),
    )
    .await
    .unwrap();

    let rebuilt_group = state
        .inner
        .db
        .get_group(&authoritative_group.id)
        .unwrap()
        .unwrap();
    let rebuilt_session = state
        .inner
        .db
        .get_session(&authoritative_session.id)
        .unwrap()
        .unwrap();
    assert_eq!(rebuilt_group.ssh_host.as_deref(), Some("shared-host"));
    assert_eq!(rebuilt_session.group_id, authoritative_group.id);

    server_task.abort();
    let _ = server_task.await;
    cleanup_state(&state);
}
