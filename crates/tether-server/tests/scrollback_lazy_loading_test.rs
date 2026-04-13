use std::sync::Arc;
use std::time::Duration;

use axum::routing::{get, post};
use axum::Router;
use base64::Engine;
use dashmap::DashMap;
use futures::StreamExt;
use tokio_tungstenite::tungstenite::Message;
use uuid::Uuid;

use tether_server::api;
use tether_server::config::{PersistenceSection, ServerConfig, ServerSection, TerminalSection};
use tether_server::persistence::Store;
use tether_server::remote::manager::RemoteManager;
use tether_server::state::{AppState, AppStateInner};
use tether_server::ws;

fn test_state() -> AppState {
    let data_dir = std::env::temp_dir()
        .join(format!("tether-scrollback-test-{}", Uuid::new_v4()))
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

    let db = Store::new(&format!("{}/tether.db", data_dir)).unwrap();
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
            semantic_event_tx: tokio::sync::mpsc::channel(1024).0,
            semantic_event_rx: std::sync::Mutex::new(None),
        }),
    }
}

fn cleanup(state: &AppState) {
    let _ = std::fs::remove_dir_all(&state.inner.config.persistence.data_dir);
}

async fn start_ws_server(state: AppState) -> u16 {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let app = Router::new()
        .route("/api/sessions", get(api::sessions::list_sessions))
        .route(
            "/api/sessions/{id}/scrollback",
            get(api::sessions::get_scrollback),
        )
        .route("/api/sessions", post(api::sessions::create_session))
        .route("/ws/session/{id}", get(ws::handler::ws_handler))
        .with_state(state);

    tokio::spawn(async move {
        axum::serve(listener, app).await.ok();
    });

    tokio::time::sleep(Duration::from_millis(10)).await;
    port
}

/// Collect all scrollback data from WS until we receive a non-scrollback message.
/// Returns (scrollback_bytes, first_non_scrollback_json).
async fn collect_scrollback(
    ws: &mut futures::stream::SplitStream<
        tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    >,
) -> (Vec<u8>, serde_json::Value) {
    let b64 = base64::engine::general_purpose::STANDARD;
    let mut scrollback = Vec::new();

    loop {
        let next = tokio::time::timeout(Duration::from_secs(2), ws.next())
            .await
            .expect("timed out collecting scrollback")
            .expect("WS stream ended")
            .expect("WS error");

        let Message::Text(text) = next else { continue };
        let json: serde_json::Value = serde_json::from_str(text.as_str()).unwrap();
        let kind = json["type"].as_str().unwrap_or_default();

        if kind == "scrollback" {
            let data = b64
                .decode(json["data"].as_str().unwrap())
                .expect("invalid base64");
            scrollback.extend_from_slice(&data);
        } else {
            return (scrollback, json);
        }
    }
}

#[tokio::test]
async fn tail_bytes_limits_initial_replay() {
    let state = test_state();
    let group = state
        .inner
        .db
        .create_group("local", "~", None, None)
        .unwrap();
    let group_id = Uuid::parse_str(&group.id).unwrap();
    let session = state
        .create_session(
            group_id,
            Some("tail-test".to_string()),
            Some("/bin/cat".to_string()),
            None,
            None,
        )
        .unwrap();

    // Write 2MB of data: 1MB of A's followed by 1MB of B's
    session
        .scrollback
        .lock()
        .unwrap()
        .append(&vec![b'A'; 1_048_576]);
    session
        .scrollback
        .lock()
        .unwrap()
        .append(&vec![b'B'; 1_048_576]);
    session.scrollback.lock().unwrap().flush();

    let port = start_ws_server(state.clone()).await;
    let url = format!(
        "ws://127.0.0.1:{}/ws/session/{}?tail_bytes=524288",
        port, session.id
    );
    let (ws, _) = tokio_tungstenite::connect_async(url).await.unwrap();
    let (_, mut read) = ws.split();

    let (scrollback, _) = collect_scrollback(&mut read).await;

    // Should receive exactly 512KB (last 512KB of the 2MB)
    assert_eq!(scrollback.len(), 524288);
    // All bytes should be B's (the last 512KB of the 2nd MB)
    assert!(scrollback.iter().all(|&b| b == b'B'));

    state.kill_session(session.id).ok();
    cleanup(&state);
}

#[tokio::test]
async fn scrollback_info_sent_after_replay() {
    let state = test_state();
    let group = state
        .inner
        .db
        .create_group("local", "~", None, None)
        .unwrap();
    let group_id = Uuid::parse_str(&group.id).unwrap();
    let session = state
        .create_session(
            group_id,
            Some("info-test".to_string()),
            Some("/bin/cat".to_string()),
            None,
            None,
        )
        .unwrap();

    // Write 100KB of scrollback
    let data_len = 102400u64;
    session
        .scrollback
        .lock()
        .unwrap()
        .append(&vec![b'X'; data_len as usize]);
    session.scrollback.lock().unwrap().flush();

    let port = start_ws_server(state.clone()).await;
    let tail = 51200u64; // 50KB tail
    let url = format!(
        "ws://127.0.0.1:{}/ws/session/{}?tail_bytes={}",
        port, session.id, tail
    );
    let (ws, _) = tokio_tungstenite::connect_async(url).await.unwrap();
    let (_, mut read) = ws.split();

    // Collect scrollback, then the first non-scrollback message should be scrollback_info
    let (scrollback, first_msg) = collect_scrollback(&mut read).await;

    assert_eq!(scrollback.len(), tail as usize);
    assert_eq!(first_msg["type"], "scrollback_info");
    assert_eq!(first_msg["total_bytes"], data_len);
    assert_eq!(first_msg["loaded_from"], data_len - tail);

    state.kill_session(session.id).ok();
    cleanup(&state);
}

#[tokio::test]
async fn scrollback_info_with_zero_history() {
    let state = test_state();
    let group = state
        .inner
        .db
        .create_group("local", "~", None, None)
        .unwrap();
    let group_id = Uuid::parse_str(&group.id).unwrap();
    let session = state
        .create_session(
            group_id,
            Some("zero-test".to_string()),
            Some("/bin/cat".to_string()),
            None,
            None,
        )
        .unwrap();

    let port = start_ws_server(state.clone()).await;
    let url = format!(
        "ws://127.0.0.1:{}/ws/session/{}",
        port, session.id
    );
    let (ws, _) = tokio_tungstenite::connect_async(url).await.unwrap();
    let (_, mut read) = ws.split();

    // No scrollback written, first message should be scrollback_info
    let (scrollback, first_msg) = collect_scrollback(&mut read).await;

    assert!(scrollback.is_empty());
    assert_eq!(first_msg["type"], "scrollback_info");
    assert_eq!(first_msg["total_bytes"], 0);
    assert_eq!(first_msg["loaded_from"], 0);

    state.kill_session(session.id).ok();
    cleanup(&state);
}

#[tokio::test]
async fn rest_scrollback_range_read() {
    let state = test_state();
    let group = state
        .inner
        .db
        .create_group("local", "~", None, None)
        .unwrap();
    let group_id = Uuid::parse_str(&group.id).unwrap();
    let session = state
        .create_session(
            group_id,
            Some("range-test".to_string()),
            Some("/bin/cat".to_string()),
            None,
            None,
        )
        .unwrap();

    session.scrollback.lock().unwrap().append(b"AAAAABBBBB");
    session.scrollback.lock().unwrap().flush();

    let port = start_ws_server(state.clone()).await;
    let b64 = base64::engine::general_purpose::STANDARD;

    // Read first 5 bytes
    let resp: serde_json::Value = reqwest::get(format!(
        "http://127.0.0.1:{}/api/sessions/{}/scrollback?offset=0&limit=5",
        port, session.id
    ))
    .await
    .unwrap()
    .json()
    .await
    .unwrap();
    let data = b64.decode(resp["data"].as_str().unwrap()).unwrap();
    assert_eq!(data, b"AAAAA");

    // Read last 5 bytes
    let resp: serde_json::Value = reqwest::get(format!(
        "http://127.0.0.1:{}/api/sessions/{}/scrollback?offset=5&limit=5",
        port, session.id
    ))
    .await
    .unwrap()
    .json()
    .await
    .unwrap();
    let data = b64.decode(resp["data"].as_str().unwrap()).unwrap();
    assert_eq!(data, b"BBBBB");

    // Read middle range
    let resp: serde_json::Value = reqwest::get(format!(
        "http://127.0.0.1:{}/api/sessions/{}/scrollback?offset=3&limit=4",
        port, session.id
    ))
    .await
    .unwrap()
    .json()
    .await
    .unwrap();
    let data = b64.decode(resp["data"].as_str().unwrap()).unwrap();
    assert_eq!(data, b"AABB");

    state.kill_session(session.id).ok();
    cleanup(&state);
}

#[tokio::test]
async fn concurrent_clients_get_independent_replay() {
    let state = test_state();
    let group = state
        .inner
        .db
        .create_group("local", "~", None, None)
        .unwrap();
    let group_id = Uuid::parse_str(&group.id).unwrap();
    let session = state
        .create_session(
            group_id,
            Some("concurrent-test".to_string()),
            Some("/bin/cat".to_string()),
            None,
            None,
        )
        .unwrap();

    session
        .scrollback
        .lock()
        .unwrap()
        .append(&vec![b'Z'; 1000]);
    session.scrollback.lock().unwrap().flush();

    let port = start_ws_server(state.clone()).await;

    // Client A: tail_bytes=100
    let url_a = format!(
        "ws://127.0.0.1:{}/ws/session/{}?tail_bytes=100",
        port, session.id
    );
    let (ws_a, _) = tokio_tungstenite::connect_async(url_a).await.unwrap();
    let (_, mut read_a) = ws_a.split();

    // Client B: tail_bytes=500
    let url_b = format!(
        "ws://127.0.0.1:{}/ws/session/{}?tail_bytes=500",
        port, session.id
    );
    let (ws_b, _) = tokio_tungstenite::connect_async(url_b).await.unwrap();
    let (_, mut read_b) = ws_b.split();

    let (scrollback_a, info_a) = collect_scrollback(&mut read_a).await;
    let (scrollback_b, info_b) = collect_scrollback(&mut read_b).await;

    assert_eq!(scrollback_a.len(), 100);
    assert_eq!(scrollback_b.len(), 500);
    assert_eq!(info_a["type"], "scrollback_info");
    assert_eq!(info_b["type"], "scrollback_info");
    assert_eq!(info_a["loaded_from"], 900); // 1000 - 100
    assert_eq!(info_b["loaded_from"], 500); // 1000 - 500

    state.kill_session(session.id).ok();
    cleanup(&state);
}

#[tokio::test]
async fn tail_bytes_and_offset_priority() {
    let state = test_state();
    let group = state
        .inner
        .db
        .create_group("local", "~", None, None)
        .unwrap();
    let group_id = Uuid::parse_str(&group.id).unwrap();
    let session = state
        .create_session(
            group_id,
            Some("priority-test".to_string()),
            Some("/bin/cat".to_string()),
            None,
            None,
        )
        .unwrap();

    session.scrollback.lock().unwrap().append(b"0123456789");
    session.scrollback.lock().unwrap().flush();

    let port = start_ws_server(state.clone()).await;

    // offset=3 should take priority over tail_bytes=4 → replay from byte 3
    let url = format!(
        "ws://127.0.0.1:{}/ws/session/{}?offset=3&tail_bytes=4",
        port, session.id
    );
    let (ws, _) = tokio_tungstenite::connect_async(url).await.unwrap();
    let (_, mut read) = ws.split();
    let (scrollback, info) = collect_scrollback(&mut read).await;
    assert_eq!(scrollback, b"3456789");
    assert_eq!(info["type"], "scrollback_info");
    assert_eq!(info["loaded_from"], 3);

    // offset=0 with tail_bytes=4: offset=0 is NOT > 0, so tail_bytes wins → last 4 bytes
    let url2 = format!(
        "ws://127.0.0.1:{}/ws/session/{}?offset=0&tail_bytes=4",
        port, session.id
    );
    let (ws2, _) = tokio_tungstenite::connect_async(url2).await.unwrap();
    let (_, mut read2) = ws2.split();
    let (scrollback2, info2) = collect_scrollback(&mut read2).await;
    assert_eq!(scrollback2, b"6789");
    assert_eq!(info2["loaded_from"], 6);

    state.kill_session(session.id).ok();
    cleanup(&state);
}
