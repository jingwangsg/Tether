use axum::body::Body;
use axum::extract::{Json, Path, State};
use axum::http::{Request, StatusCode};
use axum::middleware;
use axum::routing::{delete, get, patch, post};
use axum::Router;
use http_body_util::BodyExt;
use serde_json::Value;
use tower::ServiceExt;

use tether_server::api;
use tether_server::auth;
use tether_server::config::{PersistenceSection, ServerConfig, ServerSection, TerminalSection};
use tether_server::persistence::Store;
use tether_server::state::{AppState, AppStateInner};

use dashmap::DashMap;
use std::sync::Arc;

/// Build an AppState backed by an in-memory SQLite DB and a unique temp data dir.
fn test_state() -> AppState {
    let data_dir = std::env::temp_dir()
        .join(format!("tether-api-test-{}", uuid::Uuid::new_v4()))
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

    // Use the temp data_dir for the DB file (not :memory: since AppState::new does this)
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

/// Build the same router as server.rs (minus WS route).
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

#[derive(Clone)]
struct MockRemoteGroupsState {
    groups: Arc<tokio::sync::Mutex<Vec<Value>>>,
    fail_sessions_list: bool,
}

async fn remote_list_groups(State(state): State<MockRemoteGroupsState>) -> Json<Vec<Value>> {
    Json(state.groups.lock().await.clone())
}

async fn remote_list_sessions(
    State(state): State<MockRemoteGroupsState>,
) -> Result<Json<Vec<Value>>, StatusCode> {
    if state.fail_sessions_list {
        return Err(StatusCode::INTERNAL_SERVER_ERROR);
    }
    Ok(Json(Vec::new()))
}

async fn remote_create_group(
    State(state): State<MockRemoteGroupsState>,
    Json(body): Json<Value>,
) -> (StatusCode, Json<Value>) {
    let mut groups = state.groups.lock().await;
    let now = chrono::Utc::now().to_rfc3339();
    let group = serde_json::json!({
        "id": uuid::Uuid::new_v4().to_string(),
        "name": body["name"].as_str().unwrap_or("remote"),
        "default_cwd": body["default_cwd"].as_str().unwrap_or("~"),
        "sort_order": groups.len() as i32,
        "parent_id": body.get("parent_id").cloned().unwrap_or(Value::Null),
        "ssh_host": Value::Null,
        "created_at": now,
        "updated_at": now,
    });
    groups.push(group.clone());
    (StatusCode::CREATED, Json(group))
}

async fn remote_update_group(
    Path(id): Path<String>,
    State(state): State<MockRemoteGroupsState>,
    Json(body): Json<Value>,
) -> StatusCode {
    let mut groups = state.groups.lock().await;
    let Some(group) = groups
        .iter_mut()
        .find(|group| group["id"].as_str() == Some(id.as_str()))
    else {
        return StatusCode::NOT_FOUND;
    };
    if let Some(name) = body.get("name").and_then(Value::as_str) {
        group["name"] = Value::String(name.to_string());
    }
    if let Some(default_cwd) = body.get("default_cwd").and_then(Value::as_str) {
        group["default_cwd"] = Value::String(default_cwd.to_string());
    }
    if let Some(sort_order) = body.get("sort_order").and_then(Value::as_i64) {
        group["sort_order"] = Value::Number(sort_order.into());
    }
    group["updated_at"] = Value::String(chrono::Utc::now().to_rfc3339());
    StatusCode::OK
}

async fn remote_delete_group(
    Path(id): Path<String>,
    State(state): State<MockRemoteGroupsState>,
) -> StatusCode {
    let mut groups = state.groups.lock().await;
    let before = groups.len();
    groups.retain(|group| group["id"].as_str() != Some(id.as_str()));
    if groups.len() == before {
        return StatusCode::NOT_FOUND;
    }
    StatusCode::OK
}

async fn remote_reorder_groups(
    State(state): State<MockRemoteGroupsState>,
    Json(items): Json<Vec<Value>>,
) -> StatusCode {
    let mut groups = state.groups.lock().await;
    for item in items {
        let Some(id) = item.get("id").and_then(Value::as_str) else {
            return StatusCode::BAD_REQUEST;
        };
        let Some(sort_order) = item.get("sort_order").and_then(Value::as_i64) else {
            return StatusCode::BAD_REQUEST;
        };
        let Some(group) = groups
            .iter_mut()
            .find(|group| group["id"].as_str() == Some(id))
        else {
            return StatusCode::NOT_FOUND;
        };
        group["sort_order"] = Value::Number(sort_order.into());
    }
    StatusCode::OK
}

async fn start_mock_remote_groups_server() -> u16 {
    start_mock_remote_groups_server_with_options(false).await
}

async fn start_mock_remote_groups_server_with_options(fail_sessions_list: bool) -> u16 {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let app = Router::new()
        .route(
            "/api/groups",
            get(remote_list_groups).post(remote_create_group),
        )
        .route("/api/groups/{id}", patch(remote_update_group))
        .route("/api/groups/{id}", delete(remote_delete_group))
        .route("/api/groups/reorder", post(remote_reorder_groups))
        .route("/api/sessions", get(remote_list_sessions))
        .with_state(MockRemoteGroupsState {
            groups: Arc::new(tokio::sync::Mutex::new(Vec::new())),
            fail_sessions_list,
        });
    tokio::spawn(async move {
        axum::serve(listener, app).await.ok();
    });
    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    port
}

// --- Tests ---

#[tokio::test]
async fn test_get_info() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/info")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["name"], "tether");
    assert!(json["version"].is_string());
    assert_eq!(json["sessions_count"], 0);

    cleanup_state(&state);
}

#[tokio::test]
async fn test_create_and_list_groups() {
    let state = test_state();
    let app = test_router(state.clone());

    // Create a group
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"name": "dev", "default_cwd": "/tmp"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let group: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(group["name"], "dev");
    assert_eq!(group["default_cwd"], "/tmp");
    let group_id = group["id"].as_str().unwrap().to_string();

    // List groups
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/groups")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let groups: Vec<serde_json::Value> = serde_json::from_slice(&body).unwrap();
    assert_eq!(groups.len(), 1);
    assert_eq!(groups[0]["id"].as_str().unwrap(), group_id);

    cleanup_state(&state);
}

#[tokio::test]
async fn test_update_group() {
    let state = test_state();
    let app = test_router(state.clone());

    // Create
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(serde_json::json!({"name": "old"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let group: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let id = group["id"].as_str().unwrap();

    // Update
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri(format!("/api/groups/{}", id))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"name": "new", "default_cwd": "/updated"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    // Verify via list
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/groups")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let groups: Vec<serde_json::Value> = serde_json::from_slice(&body).unwrap();
    assert_eq!(groups[0]["name"], "new");
    assert_eq!(groups[0]["default_cwd"], "/updated");

    cleanup_state(&state);
}

#[tokio::test]
async fn test_delete_group() {
    let state = test_state();
    let app = test_router(state.clone());

    // Create
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"name": "doomed"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let group: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let id = group["id"].as_str().unwrap();

    // Delete
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(format!("/api/groups/{}", id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    // Verify empty
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/groups")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let groups: Vec<serde_json::Value> = serde_json::from_slice(&body).unwrap();
    assert!(groups.is_empty());

    cleanup_state(&state);
}

#[tokio::test]
async fn test_list_sessions_empty() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/sessions")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let sessions: Vec<serde_json::Value> = serde_json::from_slice(&body).unwrap();
    assert!(sessions.is_empty());

    cleanup_state(&state);
}

#[tokio::test]
async fn test_get_ssh_hosts() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/ssh/hosts")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    // Should return OK with some array (may be empty if no ~/.ssh/config)
    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let hosts: Vec<serde_json::Value> = serde_json::from_slice(&body).unwrap();
    // Just check it deserialized as a valid array; contents depend on the system
    let _ = hosts;

    cleanup_state(&state);
}

#[tokio::test]
async fn test_batch_reorder_groups() {
    let state = test_state();
    let app = test_router(state.clone());

    // Create 3 groups
    let mut ids = Vec::new();
    for name in &["a", "b", "c"] {
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
        ids.push(group["id"].as_str().unwrap().to_string());
    }

    // Reorder: c=0, a=1, b=2
    let reorder_payload = serde_json::json!([
        {"id": ids[2], "sort_order": 0},
        {"id": ids[0], "sort_order": 1},
        {"id": ids[1], "sort_order": 2},
    ]);

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups/reorder")
                .header("content-type", "application/json")
                .body(Body::from(reorder_payload.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    // Verify order
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/groups")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let groups: Vec<serde_json::Value> = serde_json::from_slice(&body).unwrap();
    assert_eq!(groups[0]["id"].as_str().unwrap(), ids[2]); // c first
    assert_eq!(groups[1]["id"].as_str().unwrap(), ids[0]); // a second
    assert_eq!(groups[2]["id"].as_str().unwrap(), ids[1]); // b third

    cleanup_state(&state);
}

#[tokio::test]
async fn test_create_group_with_parent() {
    let state = test_state();
    let app = test_router(state.clone());

    // Create parent
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"name": "parent"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let parent: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let parent_id = parent["id"].as_str().unwrap().to_string();

    // Create child with parent_id
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"name": "child", "parent_id": parent_id}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let child: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(child["parent_id"].as_str().unwrap(), parent_id);

    cleanup_state(&state);
}

#[tokio::test]
async fn test_create_group_with_invalid_parent_returns_400() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"name": "orphan", "parent_id": "nonexistent"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    cleanup_state(&state);
}

#[tokio::test]
async fn test_auth_required_when_token_set() {
    let data_dir = std::env::temp_dir()
        .join(format!("tether-api-test-{}", uuid::Uuid::new_v4()))
        .to_string_lossy()
        .to_string();
    std::fs::create_dir_all(&data_dir).unwrap();

    let config = ServerConfig {
        server: ServerSection {
            bind: "127.0.0.1".to_string(),
            port: 0,
            auth_token: Some("secret-token".to_string()),
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
    let state = AppState {
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
    };

    let app = test_router(state.clone());

    // Request without auth token -> 401
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/groups")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    // Request with wrong token -> 401
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/groups")
                .header("authorization", "Bearer wrong-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    // Request with correct token -> 200
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/groups")
                .header("authorization", "Bearer secret-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // /api/info is public (no auth needed)
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/info")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let _ = std::fs::remove_dir_all(&data_dir);
}

// --- SSH Host on Groups ---

#[tokio::test]
async fn test_create_group_with_ssh_host() {
    let state = test_state();
    let app = test_router(state.clone());
    let remote_port = start_mock_remote_groups_server().await;
    state
        .inner
        .remote_manager
        .inject_ready_for_testing("devbox", remote_port);

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "name": "remote-dev",
                        "default_cwd": "~/projects",
                        "ssh_host": "devbox"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let group: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(group["name"], "remote-dev");
    assert_eq!(group["default_cwd"], "~/projects");
    assert_eq!(group["ssh_host"], "devbox");

    // Verify via list
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/groups")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let groups: Vec<serde_json::Value> = serde_json::from_slice(&body).unwrap();
    assert_eq!(groups.len(), 1);
    assert_eq!(groups[0]["ssh_host"], "devbox");

    cleanup_state(&state);
}

#[tokio::test]
async fn test_remote_groups_append_to_end_of_host_scope_by_default() {
    let state = test_state();
    let app = test_router(state.clone());
    let remote_port = start_mock_remote_groups_server().await;
    state
        .inner
        .remote_manager
        .inject_ready_for_testing("devbox", remote_port);

    for name in ["alpha", "beta"] {
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/groups")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({
                            "name": name,
                            "ssh_host": "devbox"
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);
    }

    let remote_groups = state.inner.db.get_groups_by_ssh_host("devbox").unwrap();
    assert_eq!(remote_groups.len(), 2);
    assert_eq!(remote_groups[0].name, "alpha");
    assert_eq!(remote_groups[0].sort_order, 0);
    assert_eq!(remote_groups[1].name, "beta");
    assert_eq!(remote_groups[1].sort_order, 1);

    cleanup_state(&state);
}

#[tokio::test]
async fn test_create_group_with_ssh_host_succeeds_when_followup_sync_fails() {
    let state = test_state();
    let app = test_router(state.clone());
    let remote_port = start_mock_remote_groups_server_with_options(true).await;
    state
        .inner
        .remote_manager
        .inject_ready_for_testing("devbox", remote_port);

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "name": "remote-shared",
                        "ssh_host": "devbox",
                        "default_cwd": "/srv/app"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(
        resp.status(),
        StatusCode::CREATED,
        "remote group create should not fail after authoritative create succeeded"
    );

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let group: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(group["name"], "remote-shared");
    assert_eq!(group["ssh_host"], "devbox");

    let local_groups = state.inner.db.get_groups_by_ssh_host("devbox").unwrap();
    assert_eq!(local_groups.len(), 1);
    assert_eq!(local_groups[0].name, "remote-shared");

    cleanup_state(&state);
}

#[tokio::test]
async fn test_remote_group_mutations_succeed_when_followup_sync_fails() {
    let state = test_state();
    let app = test_router(state.clone());
    let remote_port = start_mock_remote_groups_server_with_options(true).await;
    state
        .inner
        .remote_manager
        .inject_ready_for_testing("devbox", remote_port);

    let create_alpha_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "name": "alpha",
                        "ssh_host": "devbox"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(create_alpha_resp.status(), StatusCode::CREATED);
    let create_alpha_body = create_alpha_resp
        .into_body()
        .collect()
        .await
        .unwrap()
        .to_bytes();
    let first_group: serde_json::Value = serde_json::from_slice(&create_alpha_body).unwrap();
    let first_group_id = first_group["id"].as_str().unwrap().to_string();

    let create_beta_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "name": "beta",
                        "ssh_host": "devbox"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(create_beta_resp.status(), StatusCode::CREATED);
    let create_beta_body = create_beta_resp
        .into_body()
        .collect()
        .await
        .unwrap()
        .to_bytes();
    let second_group: serde_json::Value = serde_json::from_slice(&create_beta_body).unwrap();
    let second_group_id = second_group["id"].as_str().unwrap().to_string();

    let update_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri(format!("/api/groups/{}", first_group_id))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "name": "alpha-renamed"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(update_resp.status(), StatusCode::OK);
    let renamed = state.inner.db.get_group(&first_group_id).unwrap().unwrap();
    assert_eq!(renamed.name, "alpha-renamed");

    let reorder_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups/reorder")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!([
                        {"id": second_group_id, "sort_order": 0},
                        {"id": first_group_id, "sort_order": 1}
                    ])
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(reorder_resp.status(), StatusCode::OK);
    let reordered = state.inner.db.get_groups_by_ssh_host("devbox").unwrap();
    let alpha = reordered
        .iter()
        .find(|group| group.id == first_group_id)
        .unwrap();
    let beta = reordered
        .iter()
        .find(|group| group.id == second_group_id)
        .unwrap();
    assert_eq!(alpha.sort_order, 1);
    assert_eq!(beta.sort_order, 0);

    let delete_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(format!("/api/groups/{}", first_group_id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(delete_resp.status(), StatusCode::OK);
    assert!(state.inner.db.get_group(&first_group_id).unwrap().is_none());

    cleanup_state(&state);
}

#[tokio::test]
async fn test_create_group_without_ssh_host() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"name": "local-dev"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let group: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(group["name"], "local-dev");
    assert!(group["ssh_host"].is_null());

    cleanup_state(&state);
}

#[tokio::test]
async fn test_update_group_ssh_host() {
    let state = test_state();
    let app = test_router(state.clone());

    // Create a group without ssh_host
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"name": "test-group"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let group: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let id = group["id"].as_str().unwrap();
    assert!(group["ssh_host"].is_null());

    // Converting a local group into a remote group is no longer allowed.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri(format!("/api/groups/{}", id))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"ssh_host": "prod-server"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Verify it remained local.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/groups")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let groups: Vec<serde_json::Value> = serde_json::from_slice(&body).unwrap();
    assert!(groups[0]["ssh_host"].is_null());

    cleanup_state(&state);
}

#[tokio::test]
async fn test_update_group_clear_ssh_host() {
    let state = test_state();
    let app = test_router(state.clone());
    let remote_port = start_mock_remote_groups_server().await;
    state
        .inner
        .remote_manager
        .inject_ready_for_testing("myserver", remote_port);

    // Create with ssh_host
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"name": "remote", "ssh_host": "myserver"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let group: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let id = group["id"].as_str().unwrap();

    // Remote group locality is immutable.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri(format!("/api/groups/{}", id))
                .header("content-type", "application/json")
                .body(Body::from(serde_json::json!({"ssh_host": ""}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Verify it still belongs to the same host.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/groups")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let groups: Vec<serde_json::Value> = serde_json::from_slice(&body).unwrap();
    assert_eq!(groups[0]["ssh_host"], "myserver");

    cleanup_state(&state);
}

// --- Group cascade delete ---

#[tokio::test]
async fn test_delete_group_cascades_child_groups() {
    let state = test_state();
    let app = test_router(state.clone());

    // Create parent
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"name": "parent"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let parent: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let parent_id = parent["id"].as_str().unwrap();

    // Create child under parent
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({"name": "child", "parent_id": parent_id}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    // Delete parent
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(format!("/api/groups/{}", parent_id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Both parent and child should be gone
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/groups")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let groups: Vec<serde_json::Value> = serde_json::from_slice(&body).unwrap();
    assert!(
        groups.is_empty(),
        "deleting parent should cascade to child groups"
    );

    cleanup_state(&state);
}

#[tokio::test]
async fn test_delete_group_cascades_sessions() {
    let state = test_state();
    let app = test_router(state.clone());

    // Create group
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/groups")
                .header("content-type", "application/json")
                .body(Body::from(serde_json::json!({"name": "g"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let group: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let gid = group["id"].as_str().unwrap();

    // Create two local sessions in that group
    for name in &["s1", "s2"] {
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sessions?local=true")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({"group_id": gid, "name": name}).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);
    }

    // Verify sessions exist
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
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let sessions: Vec<serde_json::Value> = serde_json::from_slice(&body).unwrap();
    assert_eq!(sessions.len(), 2);

    // Delete the group
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(format!("/api/groups/{}", gid))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Sessions should also be gone
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
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let sessions: Vec<serde_json::Value> = serde_json::from_slice(&body).unwrap();
    assert!(
        sessions.is_empty(),
        "deleting group should cascade to its sessions"
    );

    cleanup_state(&state);
}

#[tokio::test]
async fn test_remote_completions_rejects_dangerous_chars() {
    let state = test_state();
    let app = test_router(state.clone());

    // Path with shell injection characters should return empty
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/completions/remote?host=myhost&path=~/;rm%20-rf%20/")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();
    assert!(results.is_empty());

    // Host with backticks should also be rejected
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/completions/remote?host=`evil`&path=~/")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();
    assert!(results.is_empty());

    cleanup_state(&state);
}
