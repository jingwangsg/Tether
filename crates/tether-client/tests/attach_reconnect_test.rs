use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use axum::middleware;
use axum::routing::{delete, get, patch, post};
use axum::Router;
use dashmap::DashMap;
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio::sync::{oneshot, Mutex};
use uuid::Uuid;

use tether_server::api;
use tether_server::auth;
use tether_server::config::{PersistenceSection, ServerConfig, ServerSection, TerminalSection};
use tether_server::persistence::Store;
use tether_server::remote::manager::RemoteManager;
use tether_server::remote::sync::sync_remote_host;
use tether_server::state::{AppState, AppStateInner};
use tether_server::ws;

fn test_state() -> AppState {
    test_state_with_terminal(TerminalSection::default())
}

fn test_state_with_terminal(terminal: TerminalSection) -> AppState {
    let data_dir = std::env::temp_dir()
        .join(format!("tether-client-reconnect-test-{}", Uuid::new_v4()))
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
        terminal,
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
            remote_manager: RemoteManager::new(),
            ssh_fg: DashMap::new(),
            ssh_live_sessions: DashMap::new(),
            semantic_event_tx: tokio::sync::mpsc::unbounded_channel().0,
            semantic_event_rx: std::sync::Mutex::new(None),
        }),
    }
}

fn cleanup(state: &AppState) {
    let _ = std::fs::remove_dir_all(&state.inner.config.persistence.data_dir);
}

fn full_test_router(state: AppState) -> Router {
    let api_routes = Router::new()
        .route("/api/groups", get(api::groups::list_groups))
        .route("/api/groups", post(api::groups::create_group))
        .route("/api/groups/{id}", patch(api::groups::update_group))
        .route("/api/groups/{id}", delete(api::groups::delete_group))
        .route("/api/sessions", get(api::sessions::list_sessions))
        .route("/api/sessions", post(api::sessions::create_session))
        .route("/api/sessions/{id}", patch(api::sessions::update_session))
        .route("/api/sessions/{id}", delete(api::sessions::delete_session))
        .route(
            "/api/sessions/{id}/scrollback",
            get(api::sessions::get_scrollback),
        )
        .route(
            "/api/sessions/reorder",
            post(api::sessions::batch_reorder_sessions),
        )
        .route("/api/remote/hosts", get(api::remote::list_remote_hosts))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            auth::auth_middleware,
        ));

    Router::new()
        .route("/api/info", get(api::server_info::get_info))
        .merge(api_routes)
        .route("/ws/session/{id}", get(ws::handler::ws_handler))
        .with_state(state)
}

async fn start_local_server(state: AppState) -> u16 {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();

    let app = Router::new()
        .route("/ws/session/{id}", get(ws::handler::ws_handler))
        .with_state(state);

    tokio::spawn(async move {
        axum::serve(listener, app).await.ok();
    });

    tokio::time::sleep(Duration::from_millis(10)).await;
    port
}

async fn start_test_server(app: Router) -> (u16, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let handle = tokio::spawn(async move {
        axum::serve(listener, app).await.ok();
    });
    tokio::time::sleep(Duration::from_millis(10)).await;
    (port, handle)
}

async fn start_tcp_forwarder(target_port: u16) -> (u16, oneshot::Sender<()>) {
    let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();

    let conn_handles: Arc<tokio::sync::Mutex<Vec<tokio::task::JoinHandle<()>>>> =
        Arc::new(tokio::sync::Mutex::new(vec![]));
    let conn_handles_for_accept = conn_handles.clone();

    let accept_handle = tokio::spawn(async move {
        let mut shutdown_rx = shutdown_rx;
        loop {
            tokio::select! {
                _ = &mut shutdown_rx => break,
                accept_result = listener.accept() => {
                    let Ok((mut inbound, _)) = accept_result else {
                        break;
                    };
                    let handle = tokio::spawn(async move {
                        let Ok(mut outbound) = tokio::net::TcpStream::connect(("127.0.0.1", target_port)).await else {
                            return;
                        };
                        let _ = tokio::io::copy_bidirectional(&mut inbound, &mut outbound).await;
                    });
                    conn_handles_for_accept.lock().await.push(handle);
                }
            }
        }
    });

    tokio::spawn(async move {
        let _ = accept_handle.await;
        for handle in conn_handles.lock().await.drain(..) {
            handle.abort();
        }
    });

    tokio::time::sleep(Duration::from_millis(10)).await;
    (port, shutdown_tx)
}

fn send_remote_command(
    state: &AppState,
    session_id: Uuid,
    command: &str,
) -> anyhow::Result<()> {
    let session = state
        .get_session(session_id)
        .ok_or_else(|| anyhow::anyhow!("missing remote session {session_id}"))?;
    session.write_input(command.as_bytes())
}

async fn wait_for_buffer_contains(buffer: &Arc<Mutex<Vec<u8>>>, needle: &[u8]) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(8);
    loop {
        {
            let locked = buffer.lock().await;
            if locked.windows(needle.len()).any(|window| window == needle) {
                return;
            }
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for {:?}",
            String::from_utf8_lossy(needle)
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

#[tokio::test]
async fn attach_reconnects_and_replays_missing_remote_history() {
    let local_state = test_state();
    let remote_state = test_state_with_terminal(TerminalSection {
        default_shell: String::new(),
        scrollback_memory_kb: 1,
        scrollback_disk_max_mb: 50,
    });
    let session_id = Uuid::new_v4();

    let remote_group = remote_state
        .inner
        .db
        .create_group("remote-root", "~", None, None)
        .unwrap();
    remote_state
        .create_session(
            Uuid::parse_str(&remote_group.id).unwrap(),
            Some("remote-shell".to_string()),
            Some("/bin/sh".to_string()),
            Some("~".to_string()),
            Some(session_id),
        )
        .unwrap();

    let (remote_port, remote_handle) = start_test_server(full_test_router(remote_state.clone())).await;
    let (forward_port, shutdown_forwarder) = start_tcp_forwarder(remote_port).await;
    let local_port = start_local_server(local_state.clone()).await;

    local_state
        .inner
        .remote_manager
        .inject_ready_for_testing("testhost", forward_port);
    sync_remote_host(
        &local_state.inner.db,
        "testhost",
        forward_port,
        &local_state.inner.ssh_fg,
        &local_state.inner.ssh_live_sessions,
        Some(&local_state),
    )
    .await
    .unwrap();

    let mut child = Command::new(env!("CARGO_BIN_EXE_tether-client"))
        .args([
            "attach",
            "--server",
            &format!("http://127.0.0.1:{local_port}"),
            "--session",
            &session_id.to_string(),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();

    let stdout = child.stdout.take().unwrap();
    let buffer = Arc::new(Mutex::new(Vec::new()));
    let buffer_for_reader = buffer.clone();
    let stdout_reader = tokio::spawn(async move {
        let mut stdout = stdout;
        let mut chunk = [0u8; 4096];
        loop {
            match stdout.read(&mut chunk).await {
                Ok(0) => break,
                Ok(n) => buffer_for_reader
                    .lock()
                    .await
                    .extend_from_slice(&chunk[..n]),
                Err(_) => break,
            }
        }
    });

    send_remote_command(&remote_state, session_id, "stty -echo\n").unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    send_remote_command(&remote_state, session_id, "printf '__PRE__\\n'\n").unwrap();
    wait_for_buffer_contains(&buffer, b"__PRE__").await;

    shutdown_forwarder.send(()).ok();
    tokio::time::sleep(Duration::from_millis(200)).await;

    let gap_payload = format!(
        "printf '__GAP_START__{}__GAP_END__\\n'\n",
        "X".repeat(4096)
    );
    send_remote_command(&remote_state, session_id, &gap_payload).unwrap();
    tokio::time::sleep(Duration::from_millis(150)).await;

    let (forward_port_2, shutdown_forwarder_2) = start_tcp_forwarder(remote_port).await;
    local_state
        .inner
        .remote_manager
        .inject_ready_for_testing("testhost", forward_port_2);
    sync_remote_host(
        &local_state.inner.db,
        "testhost",
        forward_port_2,
        &local_state.inner.ssh_fg,
        &local_state.inner.ssh_live_sessions,
        Some(&local_state),
    )
    .await
    .unwrap();

    send_remote_command(&remote_state, session_id, "printf '__POST__\\n'\n").unwrap();
    wait_for_buffer_contains(&buffer, b"__POST__").await;
    send_remote_command(&remote_state, session_id, "exit\n").unwrap();

    let status = tokio::time::timeout(Duration::from_secs(8), child.wait())
        .await
        .expect("timed out waiting for tether-client to exit")
        .expect("failed to wait for tether-client");
    stdout_reader.await.unwrap();
    assert!(status.success(), "tether-client exited with {status}");

    let combined = String::from_utf8_lossy(&buffer.lock().await).to_string();
    let pre = combined.find("__PRE__").expect("missing PRE marker");
    let gap_start = combined.find("__GAP_START__").expect("missing GAP_START marker");
    let gap_end = combined.find("__GAP_END__").expect("missing GAP_END marker");
    let post = combined.find("__POST__").expect("missing POST marker");
    assert!(pre < gap_start && gap_start < gap_end && gap_end < post);

    shutdown_forwarder_2.send(()).ok();
    remote_handle.abort();
    remote_state.kill_session(session_id).ok();
    cleanup(&local_state);
    cleanup(&remote_state);
}
