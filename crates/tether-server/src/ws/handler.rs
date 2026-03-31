use crate::state::AppState;
use crate::ws::protocol::{ClientMessage, ServerMessage};
use axum::extract::ws::{Message, WebSocket};
use axum::extract::{Path, Query, State, WebSocketUpgrade};
use axum::response::IntoResponse;
use base64::Engine;
use futures::stream::StreamExt;
use futures::SinkExt;
use serde::Deserialize;
use tokio_tungstenite::tungstenite;
use uuid::Uuid;

#[derive(Deserialize)]
pub struct WsQuery {
    pub token: Option<String>,
}

pub async fn ws_handler(
    ws: WebSocketUpgrade,
    Path(session_id): Path<String>,
    Query(query): Query<WsQuery>,
    State(state): State<AppState>,
) -> impl IntoResponse {
    // Auth check
    if let Some(ref expected) = state.inner.config.server.auth_token {
        let provided = query.token.as_deref().unwrap_or("");
        if provided != expected {
            return axum::http::StatusCode::UNAUTHORIZED.into_response();
        }
    }

    let session_id = match Uuid::parse_str(&session_id) {
        Ok(id) => id,
        Err(_) => return axum::http::StatusCode::BAD_REQUEST.into_response(),
    };

    ws.on_upgrade(move |socket| handle_socket(socket, session_id, state))
        .into_response()
}

async fn handle_socket(socket: WebSocket, session_id: Uuid, state: AppState) {
    // Route to remote tether-server if this session belongs to an SSH group
    if let Ok(Some(ssh_host)) = state.inner.db.get_session_ssh_host(&session_id.to_string()) {
        if let Some(port) = state.inner.remote_manager.get_tunnel_port(&ssh_host) {
            proxy_ws_to_remote(socket, session_id, port).await;
            return;
        }
        tracing::warn!("WS: remote host {} not ready for session {}", ssh_host, session_id);
        return;
    }

    let session = match state.get_session(session_id) {
        Some(s) => s,
        None => {
            tracing::warn!("WS: session {} not found", session_id);
            return;
        }
    };

    let (mut ws_sink, mut ws_stream) = socket.split();
    let b64 = base64::engine::general_purpose::STANDARD;

    // Send scrollback replay
    let scrollback = session.get_scrollback_snapshot();
    if !scrollback.is_empty() {
        let msg = ServerMessage::Scrollback {
            data: b64.encode(&scrollback),
        };
        if let Ok(json) = serde_json::to_string(&msg) {
            let _ = ws_sink.send(Message::Text(json.into())).await;
        }
    }

    // Subscribe to session output
    let mut output_rx = session.output_tx.subscribe();

    let session_for_input = session.clone();

    // Dedicated PTY writer: one long-lived blocking task drains the channel so the
    // WS receive loop never blocks waiting for a PTY write to complete.
    let (input_tx, mut input_rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
    let input_writer_session = session_for_input.clone();
    tokio::task::spawn_blocking(move || {
        while let Some(data) = input_rx.blocking_recv() {
            if input_writer_session.write_input(&data).is_err() {
                break;
            }
        }
    });

    // Channel for control messages (pong) from receive loop → send task
    let (ctrl_tx, mut ctrl_rx) = tokio::sync::mpsc::unbounded_channel::<String>();

    // Spawn task to forward session output + control messages + foreground changes to WS
    let mut shutdown_rx = state.inner.shutdown_tx.subscribe();
    let mut fg_rx = state.inner.fg_tx.subscribe();
    let send_task = tokio::spawn(async move {
        let b64_send = base64::engine::general_purpose::STANDARD;
        loop {
            tokio::select! {
                result = output_rx.recv() => {
                    match result {
                        Ok(data) => {
                            let msg = ServerMessage::Output {
                                data: b64_send.encode(&data),
                            };
                            if let Ok(json) = serde_json::to_string(&msg) {
                                if ws_sink.send(Message::Text(json.into())).await.is_err() {
                                    break;
                                }
                            }
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                            tracing::warn!("WS client lagged by {} messages", n);
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                            let msg = ServerMessage::SessionEvent {
                                event: "exited".to_string(),
                                exit_code: None,
                            };
                            if let Ok(json) = serde_json::to_string(&msg) {
                                let _ = ws_sink.send(Message::Text(json.into())).await;
                            }
                            break;
                        }
                    }
                }
                Some(json) = ctrl_rx.recv() => {
                    if ws_sink.send(Message::Text(json.into())).await.is_err() {
                        break;
                    }
                }
                result = fg_rx.recv() => {
                    match result {
                        Ok((sid, fg)) if sid == session_id => {
                            let msg = ServerMessage::ForegroundChanged {
                                process: fg.process,
                                tool_state: fg.tool_state,
                            };
                            if let Ok(json) = serde_json::to_string(&msg) {
                                if ws_sink.send(Message::Text(json.into())).await.is_err() {
                                    break;
                                }
                            }
                        }
                        Ok(_) => {} // Different session, ignore
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => {}
                    }
                }
                _ = shutdown_rx.recv() => {
                    break;
                }
            }
        }
        ws_sink
    });

    // Process incoming WS messages
    while let Some(Ok(msg)) = ws_stream.next().await {
        match msg {
            Message::Text(text) => {
                if let Ok(client_msg) = serde_json::from_str::<ClientMessage>(&text) {
                    match client_msg {
                        ClientMessage::Input { data } => {
                            if let Ok(decoded) = b64.decode(&data) {
                                let _ = input_tx.send(decoded);
                            }
                        }
                        ClientMessage::Resize { cols, rows } => {
                            session_for_input.resize(cols, rows).ok();
                            state
                                .inner
                                .db
                                .update_session_size(&session_id.to_string(), cols, rows)
                                .ok();
                        }
                        ClientMessage::Ping => {
                            if let Ok(json) = serde_json::to_string(&ServerMessage::Pong) {
                                let _ = ctrl_tx.send(json);
                            }
                        }
                        ClientMessage::Pause | ClientMessage::Resume => {}
                    }
                }
            }
            Message::Close(_) => break,
            _ => {}
        }
    }

    send_task.abort();
    tracing::debug!("WS client disconnected from session {}", session_id);
}

/// Bidirectionally proxy a Flutter WebSocket connection to a remote tether-server
/// session via the SSH tunnel.
async fn proxy_ws_to_remote(client_ws: WebSocket, session_id: Uuid, tunnel_port: u16) {
    let url = format!("ws://127.0.0.1:{}/ws/session/{}", tunnel_port, session_id);
    let remote_ws = match tokio_tungstenite::connect_async(&url).await {
        Ok((ws, _)) => ws,
        Err(e) => {
            tracing::warn!("WS proxy: failed to connect to remote {}: {}", url, e);
            return;
        }
    };

    let (mut client_sink, mut client_stream) = client_ws.split();
    let (mut remote_sink, mut remote_stream) = remote_ws.split();

    let client_to_remote = tokio::spawn(async move {
        while let Some(Ok(msg)) = client_stream.next().await {
            // Translate axum WS message → tungstenite message
            let tung_msg = match msg {
                Message::Text(t)   => tungstenite::Message::Text(t.to_string().into()),
                Message::Binary(b) => tungstenite::Message::Binary(b.to_vec().into()),
                Message::Ping(p)   => tungstenite::Message::Ping(p.to_vec().into()),
                Message::Pong(p)   => tungstenite::Message::Pong(p.to_vec().into()),
                Message::Close(_)  => break,
            };
            if remote_sink.send(tung_msg).await.is_err() {
                break;
            }
        }
    });

    // remote → client
    while let Some(Ok(msg)) = remote_stream.next().await {
        let axum_msg = match msg {
            tungstenite::Message::Text(t)   => Message::Text(t.to_string().into()),
            tungstenite::Message::Binary(b) => Message::Binary(b.to_vec().into()),
            tungstenite::Message::Ping(p)   => Message::Ping(p.to_vec().into()),
            tungstenite::Message::Pong(p)   => Message::Pong(p.to_vec().into()),
            tungstenite::Message::Close(_)  => break,
            tungstenite::Message::Frame(_)  => continue,
        };
        if client_sink.send(axum_msg).await.is_err() {
            break;
        }
    }

    client_to_remote.abort();
    tracing::debug!("WS proxy disconnected for remote session {}", session_id);
}
