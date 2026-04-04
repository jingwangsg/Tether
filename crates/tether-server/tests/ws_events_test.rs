use std::sync::Arc;
use std::time::Duration;

use axum::routing::get;
use axum::Router;
use dashmap::DashMap;
use futures::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::Message;
use uuid::Uuid;

use tether_server::config::{PersistenceSection, ServerConfig, ServerSection, TerminalSection};
use tether_server::persistence::Store;
use tether_server::remote::manager::RemoteManager;
use tether_server::state::{AppState, AppStateInner};
use tether_server::ws;

fn test_state() -> AppState {
    let data_dir = std::env::temp_dir()
        .join(format!("tether-ws-events-test-{}", Uuid::new_v4()))
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

async fn start_ws_server(state: AppState) -> u16 {
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

#[tokio::test]
async fn events_mode_sends_foreground_and_pong_but_not_output() {
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
            Some("events-test".to_string()),
            Some("printf 'hello from session'; sleep 2".to_string()),
            None,
            None,
        )
        .unwrap();

    let port = start_ws_server(state.clone()).await;
    let url = format!(
        "ws://127.0.0.1:{}/ws/session/{}?mode=events",
        port, session.id
    );
    let (mut ws, _) = tokio_tungstenite::connect_async(url).await.unwrap();

    let first = tokio::time::timeout(Duration::from_secs(1), ws.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let Message::Text(first_text) = first else {
        panic!("expected text websocket frame");
    };
    let first_json: serde_json::Value = serde_json::from_str(first_text.as_str()).unwrap();
    assert_eq!(first_json["type"], "foreground_changed");
    assert!(first_json.get("data").is_none());

    ws.send(Message::Text(r#"{"type":"ping"}"#.to_string().into()))
        .await
        .unwrap();

    let second = tokio::time::timeout(Duration::from_secs(1), ws.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let Message::Text(second_text) = second else {
        panic!("expected text websocket frame");
    };
    let second_json: serde_json::Value = serde_json::from_str(second_text.as_str()).unwrap();
    assert_eq!(second_json["type"], "pong");

    if let Ok(Some(Ok(Message::Text(text)))) =
        tokio::time::timeout(Duration::from_millis(300), ws.next()).await
    {
        let json: serde_json::Value = serde_json::from_str(text.as_str()).unwrap();
        let kind = json["type"].as_str().unwrap_or_default();
        assert_ne!(kind, "output");
        assert_ne!(kind, "scrollback");
    }

    cleanup(&state);
}
