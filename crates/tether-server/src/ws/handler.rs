use crate::remote::foreground::update_ssh_foreground_cache;
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
    pub mode: Option<String>,
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

    // For SSH-group sessions, verify the tunnel port is reachable BEFORE upgrading.
    // If we upgrade first and then fail, Flutter sees HTTP 101 ("connected"), resets
    // its reconnect-backoff counter to 0, and retries every 1 s forever.
    // Returning 503 here means Flutter treats it as a real failure and uses
    // exponential backoff instead.  ECONNREFUSED on localhost is immediate.
    if let Ok(Some(ssh_host)) = state.inner.db.get_session_ssh_host(&session_id.to_string()) {
        match state.inner.remote_manager.get_tunnel_port(&ssh_host) {
            None => return axum::http::StatusCode::SERVICE_UNAVAILABLE.into_response(),
            Some(port) => {
                if tokio::net::TcpStream::connect(("127.0.0.1", port))
                    .await
                    .is_err()
                {
                    state.inner.remote_manager.clear_dead_tunnel(&ssh_host);
                    return axum::http::StatusCode::SERVICE_UNAVAILABLE.into_response();
                }
            }
        }
    }

    let mode = query.mode.unwrap_or_default();
    ws.on_upgrade(move |socket| handle_socket(socket, session_id, mode, state))
        .into_response()
}

async fn handle_socket(socket: WebSocket, session_id: Uuid, mode: String, state: AppState) {
    // Route to remote tether-server if this session belongs to an SSH group
    if let Ok(Some(ssh_host)) = state.inner.db.get_session_ssh_host(&session_id.to_string()) {
        if let Some(port) = state.inner.remote_manager.get_tunnel_port(&ssh_host) {
            proxy_ws_to_remote(socket, session_id, port, &mode, state).await;
            return;
        }
        tracing::warn!(
            "WS: remote host {} not ready for session {}",
            ssh_host,
            session_id
        );
        return;
    }

    let session = match state.get_session(session_id) {
        Some(s) => s,
        None => {
            tracing::warn!("WS: session {} not found", session_id);
            return;
        }
    };

    if mode == "events" {
        handle_events_socket(socket, session_id, session, state).await;
        return;
    }

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

    // Send current foreground state immediately so the client reflects it
    // without waiting for the next process_monitor broadcast cycle.
    let current_fg = session.get_foreground();
    if current_fg.process.is_some() {
        let msg = ServerMessage::ForegroundChanged {
            process: current_fg.process,
            tool_state: current_fg.tool_state,
        };
        if let Ok(json) = serde_json::to_string(&msg) {
            let _ = ws_sink.send(Message::Text(json.into())).await;
        }
    }

    // Subscribe to session output
    let mut output_rx = session.output_tx.subscribe();

    let session_for_input = session.clone();
    let session_for_events = session.clone();

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
    let mut exit_check = tokio::time::interval(std::time::Duration::from_millis(250));
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
                _ = exit_check.tick() => {
                    if !session_for_events.is_alive() {
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

async fn handle_events_socket(
    socket: WebSocket,
    session_id: Uuid,
    session: std::sync::Arc<crate::pty::session::PtySession>,
    state: AppState,
) {
    let (mut ws_sink, mut ws_stream) = socket.split();

    let current_fg = session.get_foreground();
    let initial = ServerMessage::ForegroundChanged {
        process: current_fg.process,
        tool_state: current_fg.tool_state,
    };
    if let Ok(json) = serde_json::to_string(&initial) {
        if ws_sink.send(Message::Text(json.into())).await.is_err() {
            return;
        }
    }
    if !session.is_alive() {
        let msg = ServerMessage::SessionEvent {
            event: "exited".to_string(),
            exit_code: None,
        };
        if let Ok(json) = serde_json::to_string(&msg) {
            let _ = ws_sink.send(Message::Text(json.into())).await;
        }
        return;
    }
    let session_for_events = session.clone();
    drop(session);

    let mut output_rx = match state.get_session(session_id) {
        Some(session) => session.output_tx.subscribe(),
        None => {
            let msg = ServerMessage::SessionEvent {
                event: "exited".to_string(),
                exit_code: None,
            };
            if let Ok(json) = serde_json::to_string(&msg) {
                let _ = ws_sink.send(Message::Text(json.into())).await;
            }
            return;
        }
    };
    let mut shutdown_rx = state.inner.shutdown_tx.subscribe();
    let mut fg_rx = state.inner.fg_tx.subscribe();
    let (ctrl_tx, mut ctrl_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    let mut exit_check = tokio::time::interval(std::time::Duration::from_millis(250));

    let send_task = tokio::spawn(async move {
        loop {
            tokio::select! {
                result = output_rx.recv() => {
                    match result {
                        Ok(_) => {}
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
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
                        Ok(_) => {}
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => {}
                    }
                }
                _ = exit_check.tick() => {
                    if !session_for_events.is_alive() {
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
                _ = shutdown_rx.recv() => break,
            }
        }
    });

    while let Some(Ok(msg)) = ws_stream.next().await {
        match msg {
            Message::Text(text) => {
                if let Ok(ClientMessage::Ping) = serde_json::from_str::<ClientMessage>(&text) {
                    if let Ok(json) = serde_json::to_string(&ServerMessage::Pong) {
                        let _ = ctrl_tx.send(json);
                    }
                }
            }
            Message::Close(_) => break,
            _ => {}
        }
    }

    send_task.abort();
}

/// Bidirectionally proxy a Flutter WebSocket connection to a remote tether-server
/// session via the SSH tunnel. Also maintains `state.inner.ssh_fg` by intercepting
/// `foreground_changed` messages from the remote.
async fn proxy_ws_to_remote(
    client_ws: WebSocket,
    session_id: Uuid,
    tunnel_port: u16,
    mode: &str,
    state: AppState,
) {
    let mut url = format!("ws://127.0.0.1:{}/ws/session/{}", tunnel_port, session_id);
    if mode == "events" {
        url.push_str("?mode=events");
    }
    let remote_ws = match tokio_tungstenite::connect_async(&url).await {
        Ok((ws, _)) => ws,
        Err(e) => {
            tracing::warn!("WS proxy: failed to connect to remote {}: {}", url, e);
            return;
        }
    };

    let (mut client_sink, mut client_stream) = client_ws.split();
    let (mut remote_sink, mut remote_stream) = remote_ws.split();
    let _live_proxy_guard = ActiveSshProxyGuard::new(state.clone(), session_id);

    let client_to_remote = tokio::spawn(async move {
        while let Some(Ok(msg)) = client_stream.next().await {
            // Translate axum WS message → tungstenite message
            let tung_msg = match msg {
                Message::Text(t) => tungstenite::Message::Text(t.to_string().into()),
                Message::Binary(b) => tungstenite::Message::Binary(b.to_vec().into()),
                Message::Ping(p) => tungstenite::Message::Ping(p.to_vec().into()),
                Message::Pong(p) => tungstenite::Message::Pong(p.to_vec().into()),
                Message::Close(_) => break,
            };
            if remote_sink.send(tung_msg).await.is_err() {
                break;
            }
        }
    });

    // remote → client; intercept foreground_changed to keep ssh_fg cache live
    while let Some(Ok(msg)) = remote_stream.next().await {
        let axum_msg = match msg {
            tungstenite::Message::Text(ref t) => {
                // Update ssh_fg cache when remote sends a foreground_changed message.
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(t.as_str()) {
                    if v.get("type").and_then(|x| x.as_str()) == Some("foreground_changed") {
                        let tool_state = v
                            .get("tool_state")
                            .cloned()
                            .and_then(|value| serde_json::from_value(value).ok());
                        update_ssh_foreground_cache(
                            &state.inner.ssh_fg,
                            session_id,
                            v.get("process")
                                .and_then(|x| x.as_str())
                                .map(str::to_string),
                            tool_state,
                        );
                    }
                }
                Message::Text(t.to_string().into())
            }
            tungstenite::Message::Binary(b) => Message::Binary(b.to_vec().into()),
            tungstenite::Message::Ping(p) => Message::Ping(p.to_vec().into()),
            tungstenite::Message::Pong(p) => Message::Pong(p.to_vec().into()),
            tungstenite::Message::Close(_) => break,
            tungstenite::Message::Frame(_) => continue,
        };
        if client_sink.send(axum_msg).await.is_err() {
            break;
        }
    }

    client_to_remote.abort();
    tracing::debug!("WS proxy disconnected for remote session {}", session_id);
}

struct ActiveSshProxyGuard {
    state: AppState,
    session_id: Uuid,
}

impl ActiveSshProxyGuard {
    fn new(state: AppState, session_id: Uuid) -> Self {
        state
            .inner
            .ssh_live_sessions
            .entry(session_id)
            .and_modify(|count| *count += 1)
            .or_insert(1usize);
        Self { state, session_id }
    }
}

impl Drop for ActiveSshProxyGuard {
    fn drop(&mut self) {
        if let Some(mut entry) = self.state.inner.ssh_live_sessions.get_mut(&self.session_id) {
            if *entry > 1 {
                *entry -= 1;
            } else {
                drop(entry);
                self.state.inner.ssh_live_sessions.remove(&self.session_id);
            }
        }
    }
}
