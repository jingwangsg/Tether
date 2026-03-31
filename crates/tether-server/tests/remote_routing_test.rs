//! E2E tests for the remote SSH host routing logic.
//!
//! These tests verify the behaviour of the local tether-server when it handles
//! sessions that belong to groups with an `ssh_host` set, *without* requiring an
//! actual SSH connection.  The RemoteManager starts empty (no reachable hosts),
//! so the tests exercise the "tunnel not ready" code paths and verify that local
//! (non-SSH) sessions continue to work normally in the same server instance.
//!
//! Covers:
//!   POST /api/sessions            – SSH group → 503 when tunnel absent
//!   POST /api/sessions            – local group → succeeds (local=true)
//!   DELETE /api/sessions/{id}     – SSH group session → 200 (local DB cleaned up)
//!   GET  /api/sessions/{id}/scrollback – SSH group session → 503 when tunnel absent
//!   GET  /api/remote/hosts        – always returns JSON array (may be empty)
//!   GET  /api/sessions            – lists both local and SSH-group sessions from DB

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::middleware;
use axum::routing::{delete, get, patch, post};
use axum::Router;
use dashmap::DashMap;
use http_body_util::BodyExt;
use std::sync::Arc;
use tower::ServiceExt;

use tether_server::api;
use tether_server::auth;
use tether_server::config::{PersistenceSection, ServerConfig, ServerSection, TerminalSection};
use tether_server::persistence::Store;
use tether_server::remote::manager::RemoteManager;
use tether_server::state::{AppState, AppStateInner};

// ─── Test infrastructure ──────────────────────────────────────────────────────

fn test_state() -> AppState {
    let data_dir = std::env::temp_dir()
        .join(format!("tether-remote-test-{}", uuid::Uuid::new_v4()))
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
        }),
    }
}

fn test_router(state: AppState) -> Router {
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
        .with_state(state)
}

fn cleanup(state: &AppState) {
    let _ = std::fs::remove_dir_all(&state.inner.config.persistence.data_dir);
}

/// Helper: POST /api/groups and return the group id.
async fn create_group(app: &Router, name: &str, ssh_host: Option<&str>) -> String {
    let mut body = serde_json::json!({"name": name});
    if let Some(h) = ssh_host {
        body["ssh_host"] = serde_json::Value::String(h.to_string());
    }
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let g: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    g["id"].as_str().unwrap().to_string()
}

// ─── GET /api/remote/hosts ────────────────────────────────────────────────────

#[tokio::test]
async fn remote_hosts_returns_empty_array_on_fresh_server() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/remote/hosts")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let hosts: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert!(hosts.is_array());
    assert_eq!(hosts.as_array().unwrap().len(), 0);

    cleanup(&state);
}

#[tokio::test]
async fn remote_hosts_returns_json_array() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/remote/hosts")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    // Must parse as a JSON array
    let _: Vec<serde_json::Value> = serde_json::from_slice(&bytes).unwrap();

    cleanup(&state);
}

// ─── POST /api/sessions – SSH group (no tunnel) ───────────────────────────────

#[tokio::test]
async fn create_session_in_ssh_group_returns_503_when_tunnel_not_ready() {
    let state = test_state();
    let app = test_router(state.clone());

    let gid = create_group(&app, "remote-group", Some("myhost")).await;

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "group_id": gid,
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
        StatusCode::SERVICE_UNAVAILABLE,
        "should return 503 when no SSH tunnel is ready for the host"
    );

    cleanup(&state);
}

#[tokio::test]
async fn create_session_in_ssh_group_does_not_leave_db_record_on_503() {
    let state = test_state();
    let app = test_router(state.clone());

    let gid = create_group(&app, "remote-group", Some("myhost")).await;

    // Attempt creation — will fail with 503
    app.clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"group_id": gid}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    // No session record should have been persisted locally
    let sessions = state.inner.db.list_sessions().unwrap();
    assert!(
        sessions.is_empty(),
        "failed remote session creation should not leave a DB record"
    );

    cleanup(&state);
}

// ─── POST /api/sessions – local group still works ─────────────────────────────

#[tokio::test]
async fn create_session_in_local_group_succeeds_with_local_true() {
    let state = test_state();
    let app = test_router(state.clone());

    // No ssh_host → local group
    let gid = create_group(&app, "local-group", None).await;

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions?local=true")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"group_id": gid, "name": "local-session"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let session: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(session["name"], "local-session");
    assert_eq!(session["is_alive"], false); // local=true → no PTY

    cleanup(&state);
}

// ─── DELETE /api/sessions/{id} – SSH group session ───────────────────────────

#[tokio::test]
async fn delete_ssh_group_session_removes_from_db_even_without_tunnel() {
    let state = test_state();
    let app = test_router(state.clone());

    let gid = create_group(&app, "remote-group", Some("myhost")).await;

    // Insert a session record manually (simulates a session that existed before tunnel dropped)
    let session_id = uuid::Uuid::new_v4().to_string();
    state
        .inner
        .db
        .create_session(&session_id, &gid, "orphan", "ssh myhost", "~")
        .unwrap();

    assert_eq!(state.inner.db.list_sessions().unwrap().len(), 1);

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(format!("/api/sessions/{}", session_id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    assert!(
        state.inner.db.list_sessions().unwrap().is_empty(),
        "session should be removed from DB even when remote tunnel is absent"
    );

    cleanup(&state);
}

// ─── GET /api/sessions/{id}/scrollback – SSH group session ───────────────────

#[tokio::test]
async fn get_scrollback_for_ssh_session_returns_503_when_no_tunnel() {
    let state = test_state();
    let app = test_router(state.clone());

    let gid = create_group(&app, "remote-group", Some("myhost")).await;
    let session_id = uuid::Uuid::new_v4().to_string();
    state
        .inner
        .db
        .create_session(&session_id, &gid, "remote-sess", "ssh myhost", "~")
        .unwrap();

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/sessions/{}/scrollback", session_id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(
        resp.status(),
        StatusCode::SERVICE_UNAVAILABLE,
        "scrollback for remote session should be 503 when tunnel is absent"
    );

    cleanup(&state);
}

// ─── GET /api/sessions – lists SSH-group sessions from DB ────────────────────

#[tokio::test]
async fn list_sessions_includes_ssh_group_sessions_from_db() {
    let state = test_state();
    let app = test_router(state.clone());

    let local_gid = create_group(&app, "local", None).await;
    let remote_gid = create_group(&app, "remote", Some("myhost")).await;

    // Local session via API
    app.clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions?local=true")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"group_id": local_gid, "name": "local-sess"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    // Remote session directly in DB (bypassing API since tunnel is absent)
    let remote_id = uuid::Uuid::new_v4().to_string();
    state
        .inner
        .db
        .create_session(&remote_id, &remote_gid, "remote-sess", "ssh myhost", "~")
        .unwrap();

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/sessions")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let sessions: Vec<serde_json::Value> = serde_json::from_slice(&bytes).unwrap();

    assert_eq!(sessions.len(), 2, "should list both local and remote sessions");

    let names: Vec<&str> = sessions
        .iter()
        .map(|s| s["name"].as_str().unwrap())
        .collect();
    assert!(names.contains(&"local-sess"));
    assert!(names.contains(&"remote-sess"));

    cleanup(&state);
}

// ─── GET /api/sessions/{id}/scrollback – local session ───────────────────────

#[tokio::test]
async fn get_scrollback_for_local_session_returns_404_when_not_in_memory() {
    // A local session exists only in DB (is_alive=false), not in the in-memory
    // sessions DashMap.  The scrollback handler currently returns 404 for these
    // because there is no in-memory PtySession.  This test documents that behaviour.
    let state = test_state();
    let app = test_router(state.clone());

    let gid = create_group(&app, "local", None).await;

    // Create via local=true so no PTY is spawned
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions?local=true")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"group_id": gid, "name": "db-only"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let session: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    let id = session["id"].as_str().unwrap();

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/sessions/{}/scrollback", id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    // Scrollback for a DB-only local session returns 404 (no PtySession in memory)
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    cleanup(&state);
}

// ─── Store helpers ─────────────────────────────────────────────────────────────
//
// Verify the SQL helpers used to drive routing decisions.

#[tokio::test]
async fn store_get_session_ssh_host_via_api_created_group() {
    let state = test_state();
    let app = test_router(state.clone());

    let gid = create_group(&app, "ssh-group", Some("prod.server.example")).await;
    let session_id = uuid::Uuid::new_v4().to_string();
    state
        .inner
        .db
        .create_session(&session_id, &gid, "s", "ssh prod.server.example", "~")
        .unwrap();

    let ssh_host = state
        .inner
        .db
        .get_session_ssh_host(&session_id)
        .unwrap();
    assert_eq!(ssh_host, Some("prod.server.example".to_string()));

    cleanup(&state);
}

#[tokio::test]
async fn store_get_group_ssh_host_via_api_created_group() {
    let state = test_state();
    let app = test_router(state.clone());

    let gid = create_group(&app, "ssh-group", Some("build-server")).await;
    let ssh_host = state.inner.db.get_group_ssh_host(&gid).unwrap();
    assert_eq!(ssh_host, Some("build-server".to_string()));

    cleanup(&state);
}

#[tokio::test]
async fn store_get_group_ssh_host_returns_none_for_local_group() {
    let state = test_state();
    let app = test_router(state.clone());

    let gid = create_group(&app, "local-group", None).await;
    let ssh_host = state.inner.db.get_group_ssh_host(&gid).unwrap();
    assert_eq!(ssh_host, None);

    cleanup(&state);
}
