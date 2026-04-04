use std::sync::Arc;
use std::time::Duration;

use axum::routing::get;
use axum::Router;
use dashmap::DashMap;
use futures::{SinkExt, StreamExt};
use tokio::sync::oneshot;
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
            ssh_live_sessions: DashMap::new(),
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
        .route("/ws/session/{id}", get(ws::handler::ws_handler))
        .with_state(state);

    tokio::spawn(async move {
        axum::serve(listener, app).await.ok();
    });

    tokio::time::sleep(Duration::from_millis(10)).await;
    port
}

async fn start_mock_remote_foreground_server(messages: Vec<&str>) -> (u16, oneshot::Sender<()>) {
    let (shutdown_tx, mut shutdown_rx) = oneshot::channel::<()>();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let messages = messages.into_iter().map(str::to_string).collect::<Vec<_>>();

    tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = &mut shutdown_rx => break,
                accepted = listener.accept() => {
                    let Ok((stream, _)) = accepted else {
                        break;
                    };
                    let messages = messages.clone();
                    tokio::spawn(async move {
                        if let Ok(mut ws) = tokio_tungstenite::accept_async(stream).await {
                            for message in messages {
                                let _ = ws.send(Message::Text(message.into())).await;
                            }
                            while let Some(Ok(_)) = ws.next().await {}
                        }
                    });
                }
            }
        }
    });

    tokio::time::sleep(Duration::from_millis(10)).await;
    (port, shutdown_tx)
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

#[tokio::test]
async fn ssh_proxy_forwards_remote_foreground_sequence_verbatim() {
    let state = test_state();
    let session_id = Uuid::new_v4();
    let group = state
        .inner
        .db
        .create_group("remote", "~", None, Some("testhost"))
        .unwrap();
    state
        .inner
        .db
        .create_session(
            &session_id.to_string(),
            &group.id,
            "remote-session",
            "ssh testhost",
            "~",
            None,
        )
        .unwrap();

    let (remote_port, shutdown_tx) = start_mock_remote_foreground_server(vec![
        r#"{"type":"foreground_changed","process":"claude","tool_state":"running"}"#,
        r#"{"type":"foreground_changed","process":"claude","tool_state":"waiting"}"#,
        r#"{"type":"foreground_changed","process":"claude","tool_state":"running"}"#,
    ])
    .await;
    state
        .inner
        .remote_manager
        .inject_ready_for_testing("testhost", remote_port);

    let port = start_ws_server(state.clone()).await;
    let url = format!(
        "ws://127.0.0.1:{}/ws/session/{}?mode=events",
        port, session_id
    );
    let (mut ws, _) = tokio_tungstenite::connect_async(url).await.unwrap();

    for expected in ["running", "waiting", "running"] {
        let next = tokio::time::timeout(Duration::from_secs(1), ws.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let Message::Text(text) = next else {
            panic!("expected text websocket frame");
        };
        let json: serde_json::Value = serde_json::from_str(text.as_str()).unwrap();
        assert_eq!(json["type"], "foreground_changed");
        assert_eq!(json["process"], "claude");
        assert_eq!(json["tool_state"], expected);
    }

    let sessions = reqwest::get(format!("http://127.0.0.1:{}/api/sessions", port))
        .await
        .unwrap()
        .json::<Vec<serde_json::Value>>()
        .await
        .unwrap();
    let session_id = session_id.to_string();
    let listed = sessions
        .iter()
        .find(|entry| entry["id"].as_str() == Some(session_id.as_str()))
        .expect("expected mirrored SSH session");
    assert_eq!(listed["foreground_process"], "claude");
    assert_eq!(listed["tool_state"], "running");

    shutdown_tx.send(()).ok();
    cleanup(&state);
}
