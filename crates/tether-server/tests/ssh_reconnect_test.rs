//! End-to-end tests simulating SSH host disconnect and reconnect.
//!
//! Each test spins up a real local tether-server (real TCP listener, real axum
//! WebSocket handler) plus a lightweight "mock remote" server that stands in for
//! the remote tether-server reachable through an SSH tunnel.
//!
//! The RemoteManager is seeded with `inject_ready_for_testing()` so no real SSH
//! connection is needed.
//!
//! Covers:
//!   1. WS proxy disconnects cleanly when the remote server dies
//!   2. WS proxy fails fast (no hang) when the tunnel port is already dead on connect
//!   3. WS proxy recovers once the dead tunnel is replaced with a new live one
//!   4. ws_handler returns HTTP 503 (no upgrade) when tunnel dead → prevents Flutter 1s tight loop
//!   5. POST /api/sessions returns 503 (not 502) when tunnel dead, then 201 after recovery
//!   6. clear_dead_tunnel marks host Unreachable so scanner can reconnect

use axum::middleware;
use axum::routing::{delete, get, patch, post};
use axum::Router;
use dashmap::DashMap;
use futures::{SinkExt, StreamExt};
use http_body_util::BodyExt;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{oneshot, Mutex};
use tokio_tungstenite::tungstenite::Message as TungMessage;
use tower::ServiceExt;
use uuid::Uuid;

use tether_server::api;
use tether_server::auth;
use tether_server::config::{PersistenceSection, ServerConfig, ServerSection, TerminalSection};
use tether_server::persistence::Store;
use tether_server::remote::manager::RemoteManager;
use tether_server::state::{AppState, AppStateInner};
use tether_server::ws;

// ─── Test infrastructure ──────────────────────────────────────────────────────

fn test_state() -> AppState {
    let data_dir = std::env::temp_dir()
        .join(format!("tether-reconnect-test-{}", Uuid::new_v4()))
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
            remote_manager: RemoteManager::new(),
            ssh_fg: DashMap::new(),
        }),
    }
}

fn cleanup(state: &AppState) {
    let _ = std::fs::remove_dir_all(&state.inner.config.persistence.data_dir);
}

/// Full router with API + WS routes, mirroring production setup.
/// Used by tests that need to call both POST /api/sessions and WS endpoints.
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

/// Start the local tether-server's WS handler on a random port.
/// Returns the bound port; the server runs until the process exits.
async fn start_local_server(state: AppState) -> u16 {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();

    let app = Router::new()
        .route("/ws/session/{id}", get(ws::handler::ws_handler))
        .with_state(state);

    tokio::spawn(async move {
        axum::serve(listener, app).await.ok();
    });

    // Give the server a moment to start accepting
    tokio::time::sleep(Duration::from_millis(10)).await;
    port
}

/// Start a minimal mock "remote tether-server" that accepts WebSocket connections
/// at any path, sends one JSON message, then idles.
/// Returns `(port, shutdown_tx)`.  Send `()` on `shutdown_tx` to forcibly abort
/// all connections and the accept loop — simulating the SSH host going offline.
async fn start_mock_remote() -> (u16, oneshot::Sender<()>) {
    let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();

    // Use raw tokio-tungstenite so we can abort tasks (and therefore TCP sockets)
    // immediately — axum's graceful shutdown does not forcibly close WS connections.
    let conn_handles: Arc<tokio::sync::Mutex<Vec<tokio::task::JoinHandle<()>>>> =
        Arc::new(tokio::sync::Mutex::new(vec![]));
    let conn_handles_for_accept = conn_handles.clone();

    let accept_handle = tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let handle = tokio::spawn(async move {
                if let Ok(mut ws) = tokio_tungstenite::accept_async(stream).await {
                    let msg =
                        TungMessage::Text(r#"{"type":"scrollback","data":""}"#.to_string().into());
                    ws.send(msg).await.ok();
                    // Idle until client disconnects or this task is aborted
                    while let Some(Ok(_)) = ws.next().await {}
                }
            });
            conn_handles_for_accept.lock().await.push(handle);
        }
    });

    tokio::spawn(async move {
        let _ = shutdown_rx.await;
        // Abort all per-connection tasks (drops their TCP sockets immediately)
        for h in conn_handles.lock().await.drain(..) {
            h.abort();
        }
        accept_handle.abort();
    });

    tokio::time::sleep(Duration::from_millis(10)).await;
    (port, shutdown_tx)
}

/// Start a minimal HTTP-only mock "remote tether-server".
/// Handles POST /api/sessions and returns a fake 201 SessionRow response.
/// Used by tests that exercise `create_remote_session` (not the WS proxy).
async fn start_mock_remote_http(remote_group_id: String) -> u16 {
    start_mock_remote_http_with_capture(remote_group_id).await.0
}

async fn start_mock_remote_http_with_capture(
    remote_group_id: String,
) -> (u16, Arc<Mutex<Vec<serde_json::Value>>>) {
    use axum::extract::{Json, State};
    use axum::http::StatusCode;

    #[derive(Clone)]
    struct MockState {
        group_id: String,
        captured_requests: Arc<Mutex<Vec<serde_json::Value>>>,
    }

    async fn handle_create_session(
        State(s): State<MockState>,
        Json(body): Json<serde_json::Value>,
    ) -> (StatusCode, axum::Json<serde_json::Value>) {
        s.captured_requests.lock().await.push(body.clone());
        let id = body["id"]
            .as_str()
            .map(|s| s.to_string())
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        let name = body["name"].as_str().unwrap_or("mock").to_string();
        let now = "2024-01-01T00:00:00Z".to_string();
        (
            StatusCode::CREATED,
            axum::Json(serde_json::json!({
                "id": id,
                "group_id": s.group_id,
                "name": name,
                "shell": "/bin/sh",
                "cols": 80,
                "rows": 24,
                "cwd": "~",
                "created_at": now,
                "last_active": now,
                "is_alive": true,
                "sort_order": 0
            })),
        )
    }

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let captured_requests = Arc::new(Mutex::new(Vec::new()));

    let app = Router::new()
        .route("/api/sessions", post(handle_create_session))
        .with_state(MockState {
            group_id: remote_group_id,
            captured_requests: captured_requests.clone(),
        });

    tokio::spawn(async move {
        axum::serve(listener, app).await.ok();
    });

    tokio::time::sleep(Duration::from_millis(10)).await;
    (port, captured_requests)
}

async fn start_mock_remote_session_mutation_server() -> u16 {
    use axum::http::StatusCode;

    async fn fail_sync_groups() -> StatusCode {
        StatusCode::INTERNAL_SERVER_ERROR
    }

    async fn patch_session() -> StatusCode {
        StatusCode::OK
    }

    async fn reorder_sessions() -> StatusCode {
        StatusCode::OK
    }

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();

    let app = Router::new()
        .route("/api/groups", get(fail_sync_groups))
        .route("/api/sessions/{id}", patch(patch_session))
        .route("/api/sessions/reorder", post(reorder_sessions));

    tokio::spawn(async move {
        axum::serve(listener, app).await.ok();
    });

    tokio::time::sleep(Duration::from_millis(10)).await;
    port
}

// ─── Tests ────────────────────────────────────────────────────────────────────

/// After the remote server is killed (SSH disconnect), the proxied WS connection
/// should close within a reasonable timeout — not hang indefinitely.
#[tokio::test]
async fn ws_proxy_disconnects_when_remote_dies() {
    let state = test_state();
    let session_id = Uuid::new_v4();

    let (mock_port, shutdown_tx) = start_mock_remote().await;
    let local_port = start_local_server(state.clone()).await;

    // Create SSH group + session in DB
    let group = state
        .inner
        .db
        .create_group("remote-group", "~", None, Some("testhost"))
        .unwrap();
    state
        .inner
        .db
        .create_session(
            &session_id.to_string(),
            &group.id,
            "sess",
            "ssh testhost",
            "~",
            None,
        )
        .unwrap();

    // Inject Ready state pointing at the mock remote
    state
        .inner
        .remote_manager
        .inject_ready_for_testing("testhost", mock_port);

    // Connect a WS client through the local proxy
    let url = format!("ws://127.0.0.1:{}/ws/session/{}", local_port, session_id);
    let (mut ws, _) = tokio_tungstenite::connect_async(&url).await.unwrap();

    // Receive the scrollback message that the mock remote sends on connect
    let first = tokio::time::timeout(Duration::from_secs(2), ws.next())
        .await
        .expect("timed out waiting for first message from mock remote")
        .expect("WS stream ended before first message")
        .expect("WS error on first message");
    assert!(matches!(first, TungMessage::Text(_)));

    // Kill the mock remote (simulates SSH host going offline)
    shutdown_tx.send(()).ok();
    tokio::time::sleep(Duration::from_millis(100)).await;

    // The proxied connection should close within 2 s — no hang
    let outcome = tokio::time::timeout(Duration::from_secs(2), ws.next()).await;
    match outcome {
        Ok(None) | Ok(Some(Ok(TungMessage::Close(_)))) => { /* expected */ }
        Ok(Some(Err(_))) => { /* TCP error also acceptable */ }
        Err(_) => panic!("WS did not close within 2 s after remote died"),
        Ok(Some(Ok(other))) => panic!("unexpected message after remote died: {:?}", other),
    }

    cleanup(&state);
}

/// When the tunnel port is already dead on WS connect (e.g., SSH was down before
/// the client tried to reconnect), the local server must close the WS immediately
/// and not hang.
#[tokio::test]
async fn ws_proxy_fails_fast_when_tunnel_port_dead() {
    let state = test_state();
    let session_id = Uuid::new_v4();
    let local_port = start_local_server(state.clone()).await;

    // Allocate a port then immediately release it so nothing is listening there
    let dead_port = {
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let p = l.local_addr().unwrap().port();
        drop(l);
        p
    };

    // Create SSH group + session in DB, point tunnel at dead port
    let group = state
        .inner
        .db
        .create_group("remote-group", "~", None, Some("testhost"))
        .unwrap();
    state
        .inner
        .db
        .create_session(
            &session_id.to_string(),
            &group.id,
            "sess",
            "ssh testhost",
            "~",
            None,
        )
        .unwrap();
    state
        .inner
        .remote_manager
        .inject_ready_for_testing("testhost", dead_port);

    // ws_handler now returns HTTP 503 before upgrading when tunnel is dead,
    // so connect_async gets an HTTP error response rather than a 101+close.
    let url = format!("ws://127.0.0.1:{}/ws/session/{}", local_port, session_id);
    let result = tokio_tungstenite::connect_async(&url).await;
    assert!(
        result.is_err(),
        "expected HTTP 503 (no upgrade), got a successful WS connection"
    );

    cleanup(&state);
}

/// After the dead tunnel is replaced with a new live one (scanner reconnected),
/// a fresh WS client should successfully proxy to the new remote.
#[tokio::test]
async fn ws_proxy_recovers_after_ssh_reconnect() {
    let state = test_state();
    let session_id = Uuid::new_v4();

    let (mock_port, shutdown_tx) = start_mock_remote().await;
    let local_port = start_local_server(state.clone()).await;

    let group = state
        .inner
        .db
        .create_group("remote-group", "~", None, Some("testhost"))
        .unwrap();
    state
        .inner
        .db
        .create_session(
            &session_id.to_string(),
            &group.id,
            "sess",
            "ssh testhost",
            "~",
            None,
        )
        .unwrap();
    state
        .inner
        .remote_manager
        .inject_ready_for_testing("testhost", mock_port);

    // ── Confirm initial connection works ─────────────────────────────────────
    let url = format!("ws://127.0.0.1:{}/ws/session/{}", local_port, session_id);
    let (mut ws1, _) = tokio_tungstenite::connect_async(&url).await.unwrap();
    let first = tokio::time::timeout(Duration::from_secs(2), ws1.next())
        .await
        .expect("timed out waiting for initial message")
        .expect("stream ended before first message")
        .expect("WS error on first message");
    assert!(matches!(first, TungMessage::Text(_)));
    drop(ws1);

    // ── Simulate SSH disconnect: kill mock remote ─────────────────────────────
    shutdown_tx.send(()).ok();
    tokio::time::sleep(Duration::from_millis(150)).await;

    // ── Simulate scanner detecting dead tunnel and re-establishing connection ──
    // In production the scanner would run, detect is_port_alive() = false,
    // reconnect via SSH, and call inject_ready_for_testing with a new port.
    let (new_mock_port, _new_shutdown) = start_mock_remote().await;
    state
        .inner
        .remote_manager
        .inject_ready_for_testing("testhost", new_mock_port);

    // ── Confirm new WS connection reaches the new remote ─────────────────────
    let (mut ws2, _) = tokio_tungstenite::connect_async(&url).await.unwrap();
    let recovered = tokio::time::timeout(Duration::from_secs(2), ws2.next())
        .await
        .expect("timed out waiting for message after reconnect")
        .expect("stream ended before message after reconnect")
        .expect("WS error after reconnect");
    assert!(
        matches!(recovered, TungMessage::Text(_)),
        "expected data from new remote after reconnect, got: {:?}",
        recovered
    );

    cleanup(&state);
}

// ─── Tests 4–6: tight retry loop, 502→503, clear_dead_tunnel ─────────────────

/// When tunnel is dead, ws_handler must return HTTP 503 BEFORE upgrading to
/// WebSocket.  If it upgraded first (HTTP 101), Flutter would see a "successful"
/// connect, reset its backoff counter to 0, and retry every 1 s forever.
/// Returning 503 lets Flutter use proper exponential backoff.
#[tokio::test]
async fn ws_returns_503_before_upgrade_when_tunnel_dead() {
    let state = test_state();
    let session_id = Uuid::new_v4();

    let dead_port = {
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let p = l.local_addr().unwrap().port();
        drop(l);
        p
    };

    let group = state
        .inner
        .db
        .create_group("remote-group", "~", None, Some("testhost"))
        .unwrap();
    state
        .inner
        .db
        .create_session(
            &session_id.to_string(),
            &group.id,
            "sess",
            "ssh testhost",
            "~",
            None,
        )
        .unwrap();
    state
        .inner
        .remote_manager
        .inject_ready_for_testing("testhost", dead_port);

    let local_port = start_local_server(state.clone()).await;
    let url = format!("ws://127.0.0.1:{}/ws/session/{}", local_port, session_id);

    // connect_async returns an Err when the server replies with non-101
    let result = tokio_tungstenite::connect_async(&url).await;
    assert!(
        result.is_err(),
        "expected HTTP error (503), got a successful WS connection"
    );

    // Specifically, the error should be an HTTP response error (not a TCP error)
    match result.unwrap_err() {
        tokio_tungstenite::tungstenite::Error::Http(resp) => {
            assert_eq!(
                resp.status(),
                axum::http::StatusCode::SERVICE_UNAVAILABLE,
                "expected 503 SERVICE_UNAVAILABLE"
            );
        }
        other => panic!("expected HTTP error, got: {:?}", other),
    }

    cleanup(&state);
}

/// When the tunnel port is dead (but still in Ready state), POST /api/sessions
/// should return 503 SERVICE_UNAVAILABLE rather than 502 BAD_GATEWAY.
/// After injecting a live tunnel, the same POST returns 201 CREATED.
#[tokio::test]
async fn session_post_returns_503_when_tunnel_dead_then_201_after_recovery() {
    let state = test_state();
    let session_id_for_group_only = Uuid::new_v4(); // used only to set up the group

    let dead_port = {
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let p = l.local_addr().unwrap().port();
        drop(l);
        p
    };

    let group = state
        .inner
        .db
        .create_group("remote-group", "~", None, Some("testhost"))
        .unwrap();
    state
        .inner
        .remote_manager
        .inject_ready_for_testing("testhost", dead_port);

    let app = full_test_router(state.clone());

    // ── Dead tunnel → 503 ────────────────────────────────────────────────────
    let resp = app
        .clone()
        .oneshot(
            axum::http::Request::builder()
                .method("POST")
                .uri("/api/sessions")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(
                    serde_json::json!({
                        "group_id": group.id,
                        "name": "test-session"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(
        resp.status(),
        axum::http::StatusCode::SERVICE_UNAVAILABLE,
        "expected 503 when tunnel port is dead"
    );

    // clear_dead_tunnel should have been called by the handler
    assert!(
        state
            .inner
            .remote_manager
            .get_tunnel_port("testhost")
            .is_none(),
        "tunnel should be cleared after 503"
    );

    // ── Start HTTP mock remote, inject live tunnel → 201 ────────────────────
    // The mock handles POST /api/sessions and returns a valid SessionRow.
    let mock_http_port = start_mock_remote_http(group.id.clone()).await;
    state
        .inner
        .remote_manager
        .inject_ready_for_testing("testhost", mock_http_port);

    let resp2 = app
        .clone()
        .oneshot(
            axum::http::Request::builder()
                .method("POST")
                .uri("/api/sessions")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(
                    serde_json::json!({
                        "group_id": group.id,
                        "name": "recovered-session",
                        "id": session_id_for_group_only.to_string()
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(
        resp2.status(),
        axum::http::StatusCode::CREATED,
        "expected 201 after tunnel is live again"
    );
    let bytes = resp2.into_body().collect().await.unwrap().to_bytes();
    let session: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(session["name"], "recovered-session");

    cleanup(&state);
}

#[tokio::test]
async fn remote_session_create_preserves_manual_nested_ssh_command() {
    let state = test_state();
    let app = full_test_router(state.clone());

    let group = state
        .inner
        .db
        .create_group("remote-group", "~", None, Some("testhost"))
        .unwrap();
    let (mock_http_port, captured_requests) =
        start_mock_remote_http_with_capture(group.id.clone()).await;
    state
        .inner
        .remote_manager
        .inject_ready_for_testing("testhost", mock_http_port);

    let resp = app
        .clone()
        .oneshot(
            axum::http::Request::builder()
                .method("POST")
                .uri("/api/sessions")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(
                    serde_json::json!({
                        "group_id": group.id,
                        "name": "nested-ssh",
                        "command": "ssh otherbox"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), axum::http::StatusCode::CREATED);
    let captured = captured_requests.lock().await;
    assert_eq!(captured.len(), 1);
    assert_eq!(captured[0]["command"], "ssh otherbox");

    cleanup(&state);
}

#[tokio::test]
async fn remote_session_mutations_succeed_when_followup_sync_fails() {
    let state = test_state();
    let app = full_test_router(state.clone());

    let first_group = state
        .inner
        .db
        .create_group("remote-group-a", "~", None, Some("testhost"))
        .unwrap();
    let second_group = state
        .inner
        .db
        .create_group("remote-group-b", "~", None, Some("testhost"))
        .unwrap();
    state
        .inner
        .db
        .create_session(
            "11111111-1111-1111-1111-111111111111",
            &first_group.id,
            "alpha",
            "/bin/bash",
            "~",
            None,
        )
        .unwrap();
    state
        .inner
        .db
        .create_session(
            "22222222-2222-2222-2222-222222222222",
            &first_group.id,
            "beta",
            "/bin/bash",
            "~",
            None,
        )
        .unwrap();

    let port = start_mock_remote_session_mutation_server().await;
    state
        .inner
        .remote_manager
        .inject_ready_for_testing("testhost", port);

    let update_resp = app
        .clone()
        .oneshot(
            axum::http::Request::builder()
                .method("PATCH")
                .uri("/api/sessions/11111111-1111-1111-1111-111111111111")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(
                    serde_json::json!({
                        "name": "alpha-renamed",
                        "sort_order": 7,
                        "group_id": second_group.id.clone()
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(update_resp.status(), axum::http::StatusCode::OK);
    let updated = state
        .inner
        .db
        .get_session("11111111-1111-1111-1111-111111111111")
        .unwrap()
        .unwrap();
    assert_eq!(updated.name, "alpha-renamed");
    assert_eq!(updated.sort_order, 7);
    assert_eq!(updated.group_id, second_group.id);

    let reorder_resp = app
        .clone()
        .oneshot(
            axum::http::Request::builder()
                .method("POST")
                .uri("/api/sessions/reorder")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(
                    serde_json::json!([
                        {
                            "id": "22222222-2222-2222-2222-222222222222",
                            "sort_order": 0,
                            "group_id": second_group.id.clone()
                        },
                        {
                            "id": "11111111-1111-1111-1111-111111111111",
                            "sort_order": 1,
                            "group_id": second_group.id.clone()
                        }
                    ])
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(reorder_resp.status(), axum::http::StatusCode::OK);

    let reordered_alpha = state
        .inner
        .db
        .get_session("11111111-1111-1111-1111-111111111111")
        .unwrap()
        .unwrap();
    let reordered_beta = state
        .inner
        .db
        .get_session("22222222-2222-2222-2222-222222222222")
        .unwrap()
        .unwrap();
    assert_eq!(reordered_alpha.sort_order, 1);
    assert_eq!(reordered_beta.sort_order, 0);
    assert_eq!(reordered_alpha.group_id, second_group.id);
    assert_eq!(reordered_beta.group_id, second_group.id);

    cleanup(&state);
}
