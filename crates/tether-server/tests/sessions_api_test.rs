//! E2E tests for the sessions REST API.
//!
//! All tests use `?local=true` to create DB-only session records — no PTY
//! is spawned, so tests run without any process or terminal infrastructure.
//!
//! Covers:
//!   POST   /api/sessions?local=true
//!   GET    /api/sessions
//!   PATCH  /api/sessions/{id}
//!   DELETE /api/sessions/{id}
//!   POST   /api/sessions/reorder
//!   GET    /api/sessions/{id}/scrollback

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
use tether_server::pty::session::{SessionForeground, ToolState};
use tether_server::state::{AppState, AppStateInner};

// ─── Test infrastructure (mirrors api_test.rs exactly) ───────────────────────

fn test_state() -> AppState {
    let data_dir = std::env::temp_dir()
        .join(format!("tether-sessions-test-{}", uuid::Uuid::new_v4()))
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
            remote_manager: tether_server::remote::manager::RemoteManager::new(),
            ssh_fg: DashMap::new(),
        }),
    }
}

fn test_router(state: AppState) -> Router {
    let api_routes = Router::new()
        .route("/api/groups", get(api::groups::list_groups))
        .route("/api/groups", post(api::groups::create_group))
        .route("/api/groups/{id}", patch(api::groups::update_group))
        .route("/api/groups/{id}", delete(api::groups::delete_group))
        .route(
            "/api/groups/reorder",
            post(api::groups::batch_reorder_groups),
        )
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
        .route("/api/completions", get(api::completions::complete_path))
        .route(
            "/api/completions/remote",
            get(api::completions::complete_remote_path),
        )
        .route("/api/ssh/hosts", get(api::ssh::list_ssh_hosts))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            auth::auth_middleware,
        ));

    Router::new()
        .route("/api/info", get(api::server_info::get_info))
        .merge(api_routes)
        .with_state(state)
}

fn cleanup_state(state: &AppState) {
    let data_dir = state.inner.config.persistence.data_dir.clone();
    let _ = std::fs::remove_dir_all(&data_dir);
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Create a group via HTTP and return its id string.
async fn create_group(app: &Router, name: &str) -> String {
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(serde_json::json!({"name": name}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let group: serde_json::Value = serde_json::from_slice(&body).unwrap();
    group["id"].as_str().unwrap().to_string()
}

/// POST /api/sessions?local=true and return the parsed response JSON.
async fn create_local_session(
    app: &Router,
    group_id: &str,
    name: Option<&str>,
    command: Option<&str>,
    cwd: Option<&str>,
) -> serde_json::Value {
    let mut body = serde_json::json!({"group_id": group_id});
    if let Some(n) = name {
        body["name"] = serde_json::Value::String(n.to_string());
    }
    if let Some(c) = command {
        body["command"] = serde_json::Value::String(c.to_string());
    }
    if let Some(w) = cwd {
        body["cwd"] = serde_json::Value::String(w.to_string());
    }

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions?local=true")
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

/// GET /api/sessions and return parsed array.
async fn list_sessions(app: &Router) -> Vec<serde_json::Value> {
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
    serde_json::from_slice(&bytes).unwrap()
}

// ─── POST /api/sessions?local=true ───────────────────────────────────────────

#[tokio::test]
async fn test_create_session_local_returns_201_with_is_alive_false() {
    let state = test_state();
    let app = test_router(state.clone());
    let gid = create_group(&app, "mygroup").await;

    let session = create_local_session(&app, &gid, None, None, None).await;

    assert!(session["id"].is_string(), "id should be a string UUID");
    assert_eq!(session["is_alive"], false);
    assert_eq!(session["group_id"].as_str().unwrap(), gid);

    cleanup_state(&state);
}

#[tokio::test]
async fn test_create_session_stores_command_and_cwd() {
    let state = test_state();
    let app = test_router(state.clone());
    let gid = create_group(&app, "remote").await;

    let session =
        create_local_session(&app, &gid, None, Some("ssh myhost"), Some("~/projects")).await;

    // The request field is "command" but the response field is "shell" (SessionRow)
    assert_eq!(session["shell"], "ssh myhost");
    assert_eq!(session["cwd"], "~/projects");

    cleanup_state(&state);
}

#[tokio::test]
async fn test_create_session_default_name_auto_generated() {
    let state = test_state();
    let app = test_router(state.clone());
    let gid = create_group(&app, "g").await;

    let session = create_local_session(&app, &gid, None, None, None).await;

    let name = session["name"].as_str().unwrap();
    assert!(
        name.starts_with("session-"),
        "auto-generated name should start with 'session-', got: {}",
        name
    );

    cleanup_state(&state);
}

#[tokio::test]
async fn test_create_session_explicit_name_preserved() {
    let state = test_state();
    let app = test_router(state.clone());
    let gid = create_group(&app, "g").await;

    let session = create_local_session(&app, &gid, Some("my-tab"), None, None).await;

    assert_eq!(session["name"], "my-tab");

    cleanup_state(&state);
}

#[tokio::test]
async fn test_create_session_default_cwd_is_tilde() {
    let state = test_state();
    let app = test_router(state.clone());
    let gid = create_group(&app, "g").await;

    // No cwd provided
    let session = create_local_session(&app, &gid, None, None, None).await;

    assert_eq!(session["cwd"], "~");

    cleanup_state(&state);
}

#[tokio::test]
async fn test_create_session_invalid_group_id_returns_400() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions?local=true")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"group_id": "not-a-uuid"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    cleanup_state(&state);
}

// ─── GET /api/sessions ───────────────────────────────────────────────────────

#[tokio::test]
async fn test_list_sessions_returns_all_created() {
    let state = test_state();
    let app = test_router(state.clone());
    let gid = create_group(&app, "g").await;

    let s1 = create_local_session(&app, &gid, Some("alpha"), None, None).await;
    let s2 = create_local_session(&app, &gid, Some("beta"), None, None).await;
    let s3 = create_local_session(&app, &gid, Some("gamma"), None, None).await;

    let sessions = list_sessions(&app).await;
    assert_eq!(sessions.len(), 3);

    let ids: Vec<&str> = sessions.iter().map(|s| s["id"].as_str().unwrap()).collect();
    assert!(ids.contains(&s1["id"].as_str().unwrap()));
    assert!(ids.contains(&s2["id"].as_str().unwrap()));
    assert!(ids.contains(&s3["id"].as_str().unwrap()));

    cleanup_state(&state);
}

#[tokio::test]
async fn test_list_sessions_in_sort_order_after_reorder() {
    let state = test_state();
    let app = test_router(state.clone());
    let gid = create_group(&app, "g").await;

    let s1 = create_local_session(&app, &gid, Some("a"), None, None).await;
    let s2 = create_local_session(&app, &gid, Some("b"), None, None).await;
    let s3 = create_local_session(&app, &gid, Some("c"), None, None).await;

    let id1 = s1["id"].as_str().unwrap();
    let id2 = s2["id"].as_str().unwrap();
    let id3 = s3["id"].as_str().unwrap();

    // Reorder: c=0, a=1, b=2
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions/reorder")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!([
                        {"id": id3, "sort_order": 0},
                        {"id": id1, "sort_order": 1},
                        {"id": id2, "sort_order": 2},
                    ])
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let sessions = list_sessions(&app).await;
    assert_eq!(
        sessions[0]["id"].as_str().unwrap(),
        id3,
        "c should be first"
    );
    assert_eq!(
        sessions[1]["id"].as_str().unwrap(),
        id1,
        "a should be second"
    );
    assert_eq!(
        sessions[2]["id"].as_str().unwrap(),
        id2,
        "b should be third"
    );

    cleanup_state(&state);
}

// ─── PATCH /api/sessions/{id} ────────────────────────────────────────────────

#[tokio::test]
async fn test_update_session_name() {
    let state = test_state();
    let app = test_router(state.clone());
    let gid = create_group(&app, "g").await;
    let session = create_local_session(&app, &gid, Some("old-name"), None, None).await;
    let id = session["id"].as_str().unwrap();

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri(format!("/api/sessions/{}", id))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"name": "renamed"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let sessions = list_sessions(&app).await;
    let updated = sessions.iter().find(|s| s["id"] == id).unwrap();
    assert_eq!(updated["name"], "renamed");

    cleanup_state(&state);
}

#[tokio::test]
async fn test_update_session_sort_order() {
    let state = test_state();
    let app = test_router(state.clone());
    let gid = create_group(&app, "g").await;
    let s1 = create_local_session(&app, &gid, Some("x"), None, None).await;
    let s2 = create_local_session(&app, &gid, Some("y"), None, None).await;
    let id1 = s1["id"].as_str().unwrap();
    let id2 = s2["id"].as_str().unwrap();

    // Give distinct sort orders: s1→10, s2→1 (s2 should sort first)
    for (id, order) in &[(id1, 10), (id2, 1)] {
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("PATCH")
                    .uri(format!("/api/sessions/{}", id))
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({"sort_order": order}).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
    }

    // s2 (sort_order=1) should now sort before s1 (sort_order=10)
    let sessions = list_sessions(&app).await;
    assert_eq!(
        sessions[0]["id"].as_str().unwrap(),
        id2,
        "s2 (sort_order=1) should be first"
    );
    assert_eq!(
        sessions[1]["id"].as_str().unwrap(),
        id1,
        "s1 (sort_order=10) should be second"
    );

    cleanup_state(&state);
}

#[tokio::test]
async fn test_update_session_move_to_different_group() {
    let state = test_state();
    let app = test_router(state.clone());
    let gid1 = create_group(&app, "group1").await;
    let gid2 = create_group(&app, "group2").await;
    let session = create_local_session(&app, &gid1, Some("s"), None, None).await;
    let id = session["id"].as_str().unwrap();

    assert_eq!(session["group_id"].as_str().unwrap(), gid1);

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri(format!("/api/sessions/{}", id))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"group_id": gid2}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let sessions = list_sessions(&app).await;
    let moved = sessions.iter().find(|s| s["id"] == id).unwrap();
    assert_eq!(
        moved["group_id"].as_str().unwrap(),
        gid2,
        "session should be in group2 after move"
    );

    cleanup_state(&state);
}

// ─── DELETE /api/sessions/{id} ───────────────────────────────────────────────

#[tokio::test]
async fn test_delete_session_removes_from_list() {
    let state = test_state();
    let app = test_router(state.clone());
    let gid = create_group(&app, "g").await;
    let session = create_local_session(&app, &gid, Some("doomed"), None, None).await;
    let id = session["id"].as_str().unwrap();

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(format!("/api/sessions/{}", id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let sessions = list_sessions(&app).await;
    assert!(
        sessions.iter().all(|s| s["id"] != id),
        "deleted session should not appear in list"
    );

    cleanup_state(&state);
}

#[tokio::test]
async fn test_delete_session_invalid_uuid_returns_400() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/api/sessions/not-a-uuid")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    cleanup_state(&state);
}

// ─── POST /api/sessions/reorder ──────────────────────────────────────────────

#[tokio::test]
async fn test_batch_reorder_sessions() {
    let state = test_state();
    let app = test_router(state.clone());
    let gid = create_group(&app, "g").await;

    let sa = create_local_session(&app, &gid, Some("a"), None, None).await;
    let sb = create_local_session(&app, &gid, Some("b"), None, None).await;
    let sc = create_local_session(&app, &gid, Some("c"), None, None).await;
    let id_a = sa["id"].as_str().unwrap();
    let id_b = sb["id"].as_str().unwrap();
    let id_c = sc["id"].as_str().unwrap();

    // Reverse order: c=0, b=1, a=2
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions/reorder")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!([
                        {"id": id_c, "sort_order": 0},
                        {"id": id_b, "sort_order": 1},
                        {"id": id_a, "sort_order": 2},
                    ])
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let sessions = list_sessions(&app).await;
    assert_eq!(
        sessions[0]["id"].as_str().unwrap(),
        id_c,
        "c should be first"
    );
    assert_eq!(
        sessions[1]["id"].as_str().unwrap(),
        id_b,
        "b should be second"
    );
    assert_eq!(
        sessions[2]["id"].as_str().unwrap(),
        id_a,
        "a should be third"
    );

    cleanup_state(&state);
}

#[tokio::test]
async fn test_list_sessions_includes_transient_tool_state_from_cache() {
    let state = test_state();
    let app = test_router(state.clone());
    let gid = create_group(&app, "remote").await;

    let session = create_local_session(&app, &gid, Some("agent"), None, None).await;
    let session_id = session["id"].as_str().unwrap().parse().unwrap();
    state.inner.ssh_fg.insert(
        session_id,
        SessionForeground {
            process: Some("codex".to_string()),
            tool_state: Some(ToolState::Waiting),
        },
    );

    let sessions = list_sessions(&app).await;
    let listed = sessions
        .iter()
        .find(|entry| entry["id"].as_str() == session["id"].as_str())
        .unwrap();
    assert_eq!(listed["foreground_process"], "codex");
    assert_eq!(listed["tool_state"], "waiting");

    cleanup_state(&state);
}

// ─── GET /api/sessions/{id}/scrollback ───────────────────────────────────────

#[tokio::test]
async fn test_get_scrollback_for_nonexistent_session_returns_404() {
    let state = test_state();
    let app = test_router(state.clone());

    // A well-formed UUID that doesn't exist in the in-memory sessions map
    let fake_id = "00000000-0000-0000-0000-000000000001";
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/sessions/{}/scrollback", fake_id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    cleanup_state(&state);
}
