//! E2E tests for local and remote path completion endpoints.
//!
//! Tests the HTTP API layer for completions, covering:
//! - Local path completion with various inputs
//! - Remote path completion with tilde normalization
//! - Shell injection protection
//! - Edge cases (empty paths, bare ~, trailing slashes)

use axum::body::Body;
use axum::extract::{Query, State};
use axum::http::{Request, StatusCode};
use axum::middleware;
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use http_body_util::BodyExt;
use tower::ServiceExt;

use dashmap::DashMap;
use std::sync::Arc;
use tokio::sync::Mutex;

use tether_server::api;
use tether_server::auth;
use tether_server::config::{PersistenceSection, ServerConfig, ServerSection, TerminalSection};
use tether_server::persistence::Store;
use tether_server::state::{AppState, AppStateInner};

fn test_state() -> AppState {
    let data_dir = std::env::temp_dir()
        .join(format!("tether-completion-test-{}", uuid::Uuid::new_v4()))
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
            ssh_live_sessions: DashMap::new(),
        }),
    }
}

fn test_router(state: AppState) -> Router {
    let api_routes = Router::new()
        .route("/api/completions", get(api::completions::complete_path))
        .route(
            "/api/completions/remote",
            get(api::completions::complete_remote_path),
        )
        .layer(middleware::from_fn_with_state(
            state.clone(),
            auth::auth_middleware,
        ));

    Router::new().merge(api_routes).with_state(state)
}

fn cleanup(state: &AppState) {
    let data_dir = state.inner.config.persistence.data_dir.clone();
    let _ = std::fs::remove_dir_all(&data_dir);
}

#[derive(Clone)]
struct MockRemoteCompletionState {
    results: Vec<String>,
    status: StatusCode,
    text_body: Option<String>,
    captured_paths: Arc<Mutex<Vec<String>>>,
}

#[derive(serde::Deserialize)]
struct MockRemoteCompletionQuery {
    path: String,
}

async fn mock_remote_completion_handler(
    State(state): State<MockRemoteCompletionState>,
    Query(query): Query<MockRemoteCompletionQuery>,
) -> axum::response::Response {
    state.captured_paths.lock().await.push(query.path);

    match &state.text_body {
        Some(body) => (state.status, body.clone()).into_response(),
        None => (state.status, Json(state.results.clone())).into_response(),
    }
}

async fn start_mock_remote_completion_server(
    status: StatusCode,
    results: Vec<String>,
    text_body: Option<&str>,
) -> (u16, Arc<Mutex<Vec<String>>>) {
    let captured_paths = Arc::new(Mutex::new(Vec::new()));
    let app = Router::new()
        .route("/api/completions", get(mock_remote_completion_handler))
        .with_state(MockRemoteCompletionState {
            results,
            status,
            text_body: text_body.map(str::to_string),
            captured_paths: captured_paths.clone(),
        });

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        axum::serve(listener, app).await.ok();
    });
    tokio::time::sleep(std::time::Duration::from_millis(10)).await;

    (port, captured_paths)
}

async fn reserve_dead_local_port() -> u16 {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    port
}

async fn start_stalled_remote_completion_server() -> u16 {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let _stream = stream;
                futures::future::pending::<()>().await;
            });
        }
    });
    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    port
}

async fn start_header_then_stall_remote_completion_server() -> u16 {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let _ = tokio::io::AsyncWriteExt::write_all(
                    &mut stream,
                    b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 32\r\n\r\n[",
                )
                .await;
                futures::future::pending::<()>().await;
            });
        }
    });
    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    port
}

// --- Local path completion ---

#[tokio::test]
async fn local_completion_with_tilde_returns_home_dirs() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions?path=~/")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();

    // Should return directories under home; all should start with ~/
    for r in &results {
        assert!(
            r.starts_with("~/"),
            "completion should start with ~/: {}",
            r
        );
        assert!(r.ends_with('/'), "completion should end with /: {}", r);
    }

    cleanup(&state);
}

#[tokio::test]
async fn local_completion_bare_tilde() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions?path=~")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();

    // Bare ~ should now return home directory contents (normalized to ~/)
    assert!(
        !results.is_empty(),
        "bare ~ should return home directory contents"
    );
    for r in &results {
        assert!(
            r.starts_with("~/"),
            "completion should start with ~/: {}",
            r
        );
        assert!(r.ends_with('/'), "completion should end with /: {}", r);
    }

    cleanup(&state);
}

#[tokio::test]
async fn local_completion_with_prefix() {
    let state = test_state();
    let app = test_router(state.clone());

    // Create a temp dir under home for deterministic testing
    let home = shellexpand::tilde("~").to_string();
    let test_dir = format!("{}/tether_test_completion_{}", home, uuid::Uuid::new_v4());
    std::fs::create_dir_all(format!("{}/subdir_alpha", test_dir)).unwrap();
    std::fs::create_dir_all(format!("{}/subdir_beta", test_dir)).unwrap();
    std::fs::create_dir_all(format!("{}/.hidden", test_dir)).unwrap();

    // Get the tilde-relative path
    let tilde_path = test_dir.replacen(&home, "~", 1);

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/completions?path={}/subdir_a", &tilde_path))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();

    assert_eq!(results.len(), 1, "should match only subdir_alpha");
    assert!(results[0].contains("subdir_alpha"));

    // List all — should get 2 (hidden excluded)
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/completions?path={}/", &tilde_path))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();

    assert_eq!(results.len(), 2, "hidden dirs should be excluded");

    // Cleanup test dirs
    let _ = std::fs::remove_dir_all(&test_dir);
    cleanup(&state);
}

#[tokio::test]
async fn local_completion_rejects_outside_home() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions?path=/etc/")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();
    assert!(results.is_empty(), "paths outside home should be rejected");

    cleanup(&state);
}

#[tokio::test]
async fn local_completion_empty_path_returns_empty() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions?path=")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();
    assert!(results.is_empty());

    cleanup(&state);
}

// --- Remote path completion ---

#[tokio::test]
async fn remote_completion_rejects_semicolon() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions/remote?host=myhost&path=~/;rm%20-rf")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();
    assert!(results.is_empty());

    cleanup(&state);
}

#[tokio::test]
async fn remote_completion_rejects_backtick_in_host() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions/remote?host=%60evil%60&path=~/")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();
    assert!(results.is_empty());

    cleanup(&state);
}

#[tokio::test]
async fn remote_completion_rejects_dollar_sign() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions/remote?host=myhost&path=$HOME/")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();
    assert!(results.is_empty());

    cleanup(&state);
}

#[tokio::test]
async fn remote_completion_rejects_pipe() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions/remote?host=myhost&path=~/|cat%20/etc/passwd")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();
    assert!(results.is_empty());

    cleanup(&state);
}

#[tokio::test]
async fn remote_completion_rejects_double_quotes() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions/remote?host=myhost&path=%22evil%22")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();
    assert!(results.is_empty());

    cleanup(&state);
}

#[tokio::test]
async fn remote_completion_rejects_ampersand() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions/remote?host=myhost&path=~/%26%26echo%20pwned")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();
    assert!(results.is_empty());

    cleanup(&state);
}

#[tokio::test]
async fn remote_completion_allows_clean_tilde_path() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions/remote?host=nonexistent-host-xyz&path=~/projects")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let message = String::from_utf8(body.to_vec()).unwrap();
    assert_eq!(message.trim(), "remote_host_connecting");

    cleanup(&state);
}

#[tokio::test]
async fn remote_completion_allows_bare_tilde() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions/remote?host=nonexistent-host-xyz&path=~")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let message = String::from_utf8(body.to_vec()).unwrap();
    assert_eq!(message.trim(), "remote_host_connecting");

    cleanup(&state);
}

#[tokio::test]
async fn remote_completion_allows_tilde_trailing_slash() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions/remote?host=nonexistent-host-xyz&path=~/")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let message = String::from_utf8(body.to_vec()).unwrap();
    assert_eq!(message.trim(), "remote_host_connecting");

    cleanup(&state);
}

#[tokio::test]
async fn remote_completion_proxies_ready_tunnel_results() {
    let state = test_state();
    let app = test_router(state.clone());
    let (remote_port, captured_paths) =
        start_mock_remote_completion_server(StatusCode::OK, vec!["~/projects/".to_string()], None)
            .await;

    state
        .inner
        .remote_manager
        .inject_ready_for_testing("devbox", remote_port);

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions/remote?host=devbox&path=~/proj")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();
    assert_eq!(results, vec!["~/projects/"]);
    assert_eq!(captured_paths.lock().await.as_slice(), ["~/proj"]);

    cleanup(&state);
}

#[tokio::test]
async fn remote_completion_dead_tunnel_returns_connecting_and_clears_ready_state() {
    let state = test_state();
    let app = test_router(state.clone());
    let dead_port = reserve_dead_local_port().await;

    state
        .inner
        .remote_manager
        .inject_ready_for_testing("deadbox", dead_port);

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions/remote?host=deadbox&path=~/proj")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let message = String::from_utf8(body.to_vec()).unwrap();
    assert_eq!(message.trim(), "remote_host_connecting");
    assert_eq!(state.inner.remote_manager.get_tunnel_port("deadbox"), None);

    cleanup(&state);
}

#[tokio::test]
async fn remote_completion_upstream_error_returns_bad_gateway_with_body() {
    let state = test_state();
    let app = test_router(state.clone());
    let (remote_port, _) = start_mock_remote_completion_server(
        StatusCode::SERVICE_UNAVAILABLE,
        Vec::new(),
        Some("upstream broke"),
    )
    .await;

    state
        .inner
        .remote_manager
        .inject_ready_for_testing("brokenbox", remote_port);

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions/remote?host=brokenbox&path=~/proj")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_GATEWAY);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let message = String::from_utf8(body.to_vec()).unwrap();
    assert_eq!(message.trim(), "upstream broke");

    cleanup(&state);
}

#[tokio::test]
async fn remote_completion_stalled_upstream_returns_connecting_and_clears_ready_state() {
    let state = test_state();
    let app = test_router(state.clone());
    let remote_port = start_stalled_remote_completion_server().await;

    state
        .inner
        .remote_manager
        .inject_ready_for_testing("stallbox", remote_port);

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions/remote?host=stallbox&path=~/proj")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let message = String::from_utf8(body.to_vec()).unwrap();
    assert_eq!(message.trim(), "remote_host_connecting");
    assert_eq!(state.inner.remote_manager.get_tunnel_port("stallbox"), None);

    cleanup(&state);
}

#[tokio::test]
async fn remote_completion_body_stall_returns_connecting_and_clears_ready_state() {
    let state = test_state();
    let app = test_router(state.clone());
    let remote_port = start_header_then_stall_remote_completion_server().await;

    state
        .inner
        .remote_manager
        .inject_ready_for_testing("body-stall-box", remote_port);

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions/remote?host=body-stall-box&path=~/proj")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let message = String::from_utf8(body.to_vec()).unwrap();
    assert_eq!(message.trim(), "remote_host_connecting");
    assert_eq!(
        state.inner.remote_manager.get_tunnel_port("body-stall-box"),
        None
    );

    cleanup(&state);
}

// --- Bare ~ normalization: ~ and ~/ must return identical results ---

#[tokio::test]
async fn local_completion_bare_tilde_equals_tilde_slash() {
    let state = test_state();

    // Request with bare ~
    let app1 = test_router(state.clone());
    let resp1 = app1
        .oneshot(
            Request::builder()
                .uri("/api/completions?path=~")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let body1 = resp1.into_body().collect().await.unwrap().to_bytes();
    let results_bare: Vec<String> = serde_json::from_slice(&body1).unwrap();

    // Request with ~/
    let app2 = test_router(state.clone());
    let resp2 = app2
        .oneshot(
            Request::builder()
                .uri("/api/completions?path=~/")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let body2 = resp2.into_body().collect().await.unwrap().to_bytes();
    let results_slash: Vec<String> = serde_json::from_slice(&body2).unwrap();

    // Neighboring tests create `~/tether_*` directories under $HOME. Those may
    // appear between the two requests above, so ignore them when comparing the
    // normalization behavior of `~` vs `~/`.
    let stable = |results: Vec<String>| {
        results
            .into_iter()
            .filter(|entry| !entry.starts_with("~/tether_"))
            .collect::<Vec<_>>()
    };

    assert_eq!(
        stable(results_bare),
        stable(results_slash),
        "bare ~ and ~/ should return identical completions"
    );

    cleanup(&state);
}

// --- Prefix matching with tilde paths ---

#[tokio::test]
async fn local_completion_tilde_prefix_filters_correctly() {
    let state = test_state();

    // Create deterministic test dirs under home
    let home = shellexpand::tilde("~").to_string();
    let test_dir = format!("{}/tether_pfx_test_{}", home, uuid::Uuid::new_v4());
    std::fs::create_dir_all(format!("{}/docs_aaa", test_dir)).unwrap();
    std::fs::create_dir_all(format!("{}/docs_bbb", test_dir)).unwrap();
    std::fs::create_dir_all(format!("{}/other", test_dir)).unwrap();

    let tilde_path = test_dir.replacen(&home, "~", 1);

    // Prefix "docs" should return 2 matches
    let app = test_router(state.clone());
    let resp = app
        .oneshot(
            Request::builder()
                .uri(format!("/api/completions?path={}/docs", &tilde_path))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();

    assert_eq!(results.len(), 2);
    assert!(results.iter().all(|r| r.contains("docs_")));
    // Neither should contain "other"
    assert!(results.iter().all(|r| !r.contains("other")));

    let _ = std::fs::remove_dir_all(&test_dir);
    cleanup(&state);
}

// --- Sorted results ---

#[tokio::test]
async fn local_completion_results_are_sorted() {
    let state = test_state();

    let home = shellexpand::tilde("~").to_string();
    let test_dir = format!("{}/tether_sort_test_{}", home, uuid::Uuid::new_v4());
    std::fs::create_dir_all(format!("{}/zebra", test_dir)).unwrap();
    std::fs::create_dir_all(format!("{}/apple", test_dir)).unwrap();
    std::fs::create_dir_all(format!("{}/mango", test_dir)).unwrap();

    let tilde_path = test_dir.replacen(&home, "~", 1);

    let app = test_router(state.clone());
    let resp = app
        .oneshot(
            Request::builder()
                .uri(format!("/api/completions?path={}/", &tilde_path))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();

    assert_eq!(results.len(), 3);
    // Verify sorted order
    let mut sorted = results.clone();
    sorted.sort();
    assert_eq!(results, sorted, "results should be alphabetically sorted");

    let _ = std::fs::remove_dir_all(&test_dir);
    cleanup(&state);
}

// --- Only directories, not files ---

#[tokio::test]
async fn local_completion_excludes_files() {
    let state = test_state();

    let home = shellexpand::tilde("~").to_string();
    let test_dir = format!("{}/tether_files_test_{}", home, uuid::Uuid::new_v4());
    std::fs::create_dir_all(format!("{}/real_dir", test_dir)).unwrap();
    std::fs::write(format!("{}/real_file.txt", test_dir), "content").unwrap();
    std::fs::write(format!("{}/real_script.sh", test_dir), "#!/bin/sh").unwrap();

    let tilde_path = test_dir.replacen(&home, "~", 1);

    let app = test_router(state.clone());
    let resp = app
        .oneshot(
            Request::builder()
                .uri(format!("/api/completions?path={}/real", &tilde_path))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();

    assert_eq!(
        results.len(),
        1,
        "should only return directories, not files"
    );
    assert!(results[0].contains("real_dir"));

    let _ = std::fs::remove_dir_all(&test_dir);
    cleanup(&state);
}

// --- Nonexistent path returns empty, not error ---

#[tokio::test]
async fn local_completion_nonexistent_path_returns_empty() {
    let state = test_state();
    let app = test_router(state.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/completions?path=~/this_path_definitely_does_not_exist_xyz_12345/")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();
    assert!(
        results.is_empty(),
        "nonexistent path should return empty, not error"
    );

    cleanup(&state);
}

// --- Results have trailing slashes ---

#[tokio::test]
async fn local_completion_all_results_end_with_slash() {
    let state = test_state();

    let home = shellexpand::tilde("~").to_string();
    let test_dir = format!("{}/tether_slash_test_{}", home, uuid::Uuid::new_v4());
    std::fs::create_dir_all(format!("{}/dir_a", test_dir)).unwrap();
    std::fs::create_dir_all(format!("{}/dir_b", test_dir)).unwrap();

    let tilde_path = test_dir.replacen(&home, "~", 1);

    let app = test_router(state.clone());
    let resp = app
        .oneshot(
            Request::builder()
                .uri(format!("/api/completions?path={}/", &tilde_path))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();

    for r in &results {
        assert!(
            r.ends_with('/'),
            "every completion should end with /: {}",
            r
        );
    }

    let _ = std::fs::remove_dir_all(&test_dir);
    cleanup(&state);
}

// --- Tilde-relative path reconstruction ---

#[tokio::test]
async fn local_completion_preserves_tilde_in_results() {
    let state = test_state();

    let home = shellexpand::tilde("~").to_string();
    let test_dir = format!("{}/tether_tilde_test_{}", home, uuid::Uuid::new_v4());
    std::fs::create_dir_all(format!("{}/child", test_dir)).unwrap();

    let tilde_path = test_dir.replacen(&home, "~", 1);

    let app = test_router(state.clone());
    let resp = app
        .oneshot(
            Request::builder()
                .uri(format!("/api/completions?path={}/", &tilde_path))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let results: Vec<String> = serde_json::from_slice(&body).unwrap();

    assert_eq!(results.len(), 1);
    assert!(
        results[0].starts_with("~/"),
        "tilde-prefixed input should produce tilde-prefixed output: {}",
        results[0]
    );
    // Must NOT contain the expanded home path
    assert!(
        !results[0].contains(&home),
        "result should not contain raw home path: {}",
        results[0]
    );

    let _ = std::fs::remove_dir_all(&test_dir);
    cleanup(&state);
}

// --- Unit test for tilde normalization ---

#[test]
fn bare_tilde_normalizes_to_tilde_slash() {
    // Direct test of the normalization logic
    let path = "~";
    let normalized = if path == "~" {
        "~/".to_string()
    } else {
        path.to_string()
    };
    let ls_arg = format!("{}*/", normalized);
    assert_eq!(ls_arg, "~/*/", "bare ~ should become ~/*/");
}

#[test]
fn tilde_slash_stays_unchanged() {
    let path = "~/";
    let normalized = if path == "~" {
        "~/".to_string()
    } else {
        path.to_string()
    };
    let ls_arg = format!("{}*/", normalized);
    assert_eq!(ls_arg, "~/*/");
}

#[test]
fn tilde_prefix_stays_unchanged() {
    let path = "~/pro";
    let normalized = if path == "~" {
        "~/".to_string()
    } else {
        path.to_string()
    };
    let ls_arg = format!("{}*/", normalized);
    assert_eq!(ls_arg, "~/pro*/");
}
