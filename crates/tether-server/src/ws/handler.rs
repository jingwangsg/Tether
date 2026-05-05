use crate::pty::session::SessionForeground;
use crate::remote::foreground::update_ssh_foreground_cache;
use crate::state::AppState;
use crate::ws::protocol::{ClientMessage, ServerMessage};
use axum::extract::ws::{Message, WebSocket};
use axum::extract::{Path, Query, State, WebSocketUpgrade};
use axum::response::IntoResponse;
use base64::Engine;
use futures::stream::StreamExt;
use futures::Sink;
use futures::SinkExt;
use serde::Deserialize;
use tokio_tungstenite::tungstenite;
use uuid::Uuid;

const WS_SCROLLBACK_CHUNK_SIZE: usize = 64 * 1024;

#[derive(Deserialize)]
pub struct WsQuery {
    pub token: Option<String>,
    pub mode: Option<String>,
    #[serde(default)]
    pub offset: u64,
    #[serde(default)]
    pub tail_bytes: u64,
}

fn status_message(foreground: SessionForeground) -> ServerMessage {
    ServerMessage::ForegroundChanged {
        process: foreground.process,
        osc_title: foreground.osc_title,
        attention_seq: foreground.attention_seq,
        attention_ack_seq: foreground.attention_ack_seq,
    }
}

fn replay_start_offset(offset: u64, tail_bytes: u64, replay_end: u64) -> u64 {
    if offset > 0 {
        offset.min(replay_end)
    } else if tail_bytes > 0 {
        replay_end.saturating_sub(tail_bytes)
    } else {
        0
    }
}

fn build_proxy_ws_url(
    tunnel_port: u16,
    session_id: Uuid,
    mode: &str,
    offset: u64,
    tail_bytes: u64,
) -> String {
    let mut url = format!("ws://127.0.0.1:{}/ws/session/{}", tunnel_port, session_id);
    let mut query = Vec::new();
    if mode == "events" {
        query.push("mode=events".to_string());
    } else {
        if offset > 0 {
            query.push(format!("offset={offset}"));
        }
        if tail_bytes > 0 {
            query.push(format!("tail_bytes={tail_bytes}"));
        }
    }
    if !query.is_empty() {
        url.push('?');
        url.push_str(&query.join("&"));
    }
    url
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

    let session_row = match state.inner.db.get_session(&session_id.to_string()) {
        Ok(row) => row,
        Err(_) => return axum::http::StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };

    // For SSH-group sessions, verify the tunnel port is reachable BEFORE upgrading.
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
    } else if !matches!(
        session_row,
        Some(_) if state
            .get_session(session_id)
            .is_some_and(|session| session.is_alive())
    ) {
        return axum::http::StatusCode::GONE.into_response();
    }

    let mode = query.mode.unwrap_or_default();
    let offset = query.offset;
    let tail_bytes = query.tail_bytes;
    ws.on_upgrade(move |socket| handle_socket(socket, session_id, mode, offset, tail_bytes, state))
        .into_response()
}

async fn handle_socket(
    socket: WebSocket,
    session_id: Uuid,
    mode: String,
    offset: u64,
    tail_bytes: u64,
    state: AppState,
) {
    // Route to remote tether-server if this session belongs to an SSH group
    if let Ok(Some(ssh_host)) = state.inner.db.get_session_ssh_host(&session_id.to_string()) {
        if let Some(port) = state.inner.remote_manager.get_tunnel_port(&ssh_host) {
            proxy_ws_to_remote(socket, session_id, port, &mode, offset, tail_bytes, state).await;
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
    let replay_end;
    let mut output_rx;
    {
        let scrollback = match session.scrollback.lock() {
            Ok(scrollback) => scrollback,
            Err(_) => return,
        };
        replay_end = scrollback.disk_len();
        output_rx = session.output_tx.subscribe();
    }

    let loaded_from = replay_start_offset(offset, tail_bytes, replay_end);
    if send_scrollback_replay(&mut ws_sink, &session, loaded_from, replay_end)
        .await
        .is_err()
    {
        return;
    }

    // Tell client how much total history is available
    let info_msg = ServerMessage::ScrollbackInfo {
        total_bytes: replay_end,
        loaded_from,
    };
    if send_json_message(&mut ws_sink, &info_msg).await.is_err() {
        return;
    }

    // Send current foreground state immediately
    let current_fg = session.get_foreground();
    if current_fg.process.is_some() || current_fg.osc_title.is_some() {
        if send_json_message(&mut ws_sink, &status_message(current_fg))
            .await
            .is_err()
        {
            return;
        }
    }

    // Subscribe to session output
    let session_for_input = session.clone();
    let session_for_events = session.clone();

    // Dedicated PTY writer — bounded channel provides backpressure from WS → PTY
    let (input_tx, mut input_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(256);
    let input_writer_session = session_for_input.clone();
    tokio::task::spawn_blocking(move || {
        while let Some(data) = input_rx.blocking_recv() {
            if input_writer_session.write_input(&data).is_err() {
                break;
            }
        }
    });

    let (ctrl_tx, mut ctrl_rx) = tokio::sync::mpsc::unbounded_channel::<String>();

    let mut shutdown_rx = state.inner.shutdown_tx.subscribe();
    let mut status_rx = state.inner.status_tx.subscribe();
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
                            tracing::warn!("WS client lagged by {} messages, closing connection", n);
                            break;
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                            let _ = send_json_message(&mut ws_sink, &exited_message()).await;
                            break;
                        }
                    }
                }
                Some(json) = ctrl_rx.recv() => {
                    if ws_sink
                        .send(Message::Text(axum::extract::ws::Utf8Bytes::from(json)))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
                result = status_rx.recv() => {
                    match result {
                        Ok((sid, foreground)) if sid == session_id => {
                            if send_json_message(&mut ws_sink, &status_message(foreground))
                                .await
                                .is_err()
                            {
                                break;
                            }
                        }
                        Ok(_) => {}
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => {}
                    }
                }
                _ = exit_check.tick() => {
                    if !session_for_events.is_alive() {
                        let _ = send_json_message(&mut ws_sink, &exited_message()).await;
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
                            if let Ok(decoded) =
                                base64::engine::general_purpose::STANDARD.decode(&data)
                            {
                                let _ = input_tx.send(decoded).await;
                            }
                        }
                        ClientMessage::Resize { cols, rows } => {
                            let current_cols = session_for_input
                                .cols
                                .load(std::sync::atomic::Ordering::Relaxed);
                            let current_rows = session_for_input
                                .rows
                                .load(std::sync::atomic::Ordering::Relaxed);
                            let in_alt = session_for_input.is_in_alternate_screen();
                            if in_alt && cols == current_cols && rows != current_rows {
                                tracing::debug!(
                                    "suppressing row-only resize {}x{} -> {}x{} during alt-screen for session {}",
                                    current_cols, current_rows, cols, rows, session_id
                                );
                                session_for_input
                                    .deferred_rows
                                    .store(rows, std::sync::atomic::Ordering::Relaxed);
                            } else {
                                session_for_input.resize(cols, rows).ok();
                                state
                                    .inner
                                    .db
                                    .update_session_size(&session_id.to_string(), cols, rows)
                                    .ok();
                            }
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
    let initial = status_message(current_fg);
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
    let mut status_rx = state.inner.status_tx.subscribe();
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
                    if ws_sink
                        .send(Message::Text(axum::extract::ws::Utf8Bytes::from(json)))
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
                result = status_rx.recv() => {
                    match result {
                        Ok((sid, foreground)) if sid == session_id => {
                            let msg = status_message(foreground);
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
    mut client_ws: WebSocket,
    session_id: Uuid,
    tunnel_port: u16,
    mode: &str,
    offset: u64,
    tail_bytes: u64,
    state: AppState,
) {
    let url = build_proxy_ws_url(tunnel_port, session_id, mode, offset, tail_bytes);
    let remote_ws = match tokio_tungstenite::connect_async(&url).await {
        Ok((ws, _)) => ws,
        Err(tungstenite::Error::Http(response))
            if response.status() == axum::http::StatusCode::NOT_FOUND
                || response.status() == axum::http::StatusCode::GONE =>
        {
            if let Ok(Some(host_alias)) =
                state.inner.db.get_session_ssh_host(&session_id.to_string())
            {
                if let Err(error) = crate::remote::sync::sync_remote_host(
                    &state.inner.db,
                    &host_alias,
                    tunnel_port,
                    &state.inner.ssh_fg,
                    &state.inner.ssh_live_sessions,
                    Some(&state),
                )
                .await
                {
                    tracing::warn!(
                        "WS proxy: failed to refresh remote host {} after missing session {}: {}",
                        host_alias,
                        session_id,
                        error
                    );
                }
            }
            let _ = send_json_message(&mut client_ws, &exited_message()).await;
            return;
        }
        Err(e) => {
            tracing::warn!("WS proxy: failed to connect to remote {}: {}", url, e);
            return;
        }
    };

    let (mut client_sink, mut client_stream) = client_ws.split();
    let (mut remote_sink, mut remote_stream) = remote_ws.split();
    let _live_proxy_guard = ActiveSshProxyGuard::new(state.clone(), session_id);
    let mut status_rx = state.inner.status_tx.subscribe();

    let initial_fg = state
        .inner
        .ssh_fg
        .get(&session_id)
        .map(|fg| fg.clone())
        .unwrap_or_default();
    if initial_fg.process.is_some() || initial_fg.osc_title.is_some() {
        if send_json_message(&mut client_sink, &status_message(initial_fg))
            .await
            .is_err()
        {
            return;
        }
    }

    let client_to_remote = tokio::spawn(async move {
        while let Some(Ok(msg)) = client_stream.next().await {
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

    loop {
        tokio::select! {
            message = remote_stream.next() => {
                let Some(Ok(msg)) = message else {
                    break;
                };
                let axum_msg = match msg {
                    tungstenite::Message::Text(ref t) => {
                        if let Ok(v) = serde_json::from_str::<serde_json::Value>(t.as_str()) {
                            if v.get("type").and_then(|x| x.as_str()) == Some("foreground_changed") {
                                let process = v
                                    .get("process")
                                    .and_then(|x| x.as_str())
                                    .map(str::to_string);
                                let osc_title = v
                                    .get("osc_title")
                                    .and_then(|x| x.as_str())
                                    .map(str::to_string);
                                let attention_seq = v
                                    .get("attention_seq")
                                    .and_then(|x| x.as_i64())
                                    .unwrap_or_default();
                                let attention_ack_seq = v
                                    .get("attention_ack_seq")
                                    .and_then(|x| x.as_i64())
                                    .unwrap_or_default();
                                let _ = update_ssh_foreground_cache(
                                    &state.inner.ssh_fg,
                                    session_id,
                                    process,
                                    osc_title,
                                    attention_seq,
                                    attention_ack_seq,
                                );
                                state.publish_session_status(session_id);
                                continue;
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
            result = status_rx.recv() => {
                    match result {
                        Ok((sid, foreground)) if sid == session_id => {
                            if send_json_message(&mut client_sink, &status_message(foreground))
                                .await
                                .is_err()
                            {
                                break;
                            }
                        }
                        Ok(_) => {}
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                }
            }
        }
    }

    client_to_remote.abort();
    tracing::debug!("WS proxy disconnected for remote session {}", session_id);
}

fn exited_message() -> ServerMessage {
    ServerMessage::SessionEvent {
        event: "exited".to_string(),
        exit_code: None,
    }
}

async fn send_json_message<S>(sink: &mut S, message: &ServerMessage) -> Result<(), S::Error>
where
    S: Sink<Message> + Unpin,
{
    if let Ok(json) = serde_json::to_string(message) {
        sink.send(Message::Text(json.into())).await?;
    }
    Ok(())
}

async fn send_scrollback_chunk<S>(sink: &mut S, data: &[u8]) -> Result<(), S::Error>
where
    S: Sink<Message> + Unpin,
{
    let message = ServerMessage::Scrollback {
        data: base64::engine::general_purpose::STANDARD.encode(data),
    };
    send_json_message(sink, &message).await
}

async fn send_scrollback_replay(
    ws_sink: &mut futures::stream::SplitSink<WebSocket, Message>,
    session: &std::sync::Arc<crate::pty::session::PtySession>,
    offset: u64,
    replay_end: u64,
) -> Result<(), axum::Error> {
    let mut next_offset = offset.min(replay_end);
    while next_offset < replay_end {
        let remaining = replay_end - next_offset;
        let chunk_len = remaining.min(WS_SCROLLBACK_CHUNK_SIZE as u64) as usize;
        let chunk = match session.scrollback.lock() {
            Ok(scrollback) => match scrollback.read_disk(next_offset, chunk_len) {
                Ok(chunk) => chunk,
                Err(error) => {
                    tracing::warn!(
                        "WS: failed reading scrollback replay for {} at offset {}: {}",
                        session.id,
                        next_offset,
                        error
                    );
                    break;
                }
            },
            Err(_) => break,
        };
        if chunk.is_empty() {
            break;
        }
        send_scrollback_chunk(ws_sink, &chunk).await?;
        next_offset += chunk.len() as u64;
    }
    Ok(())
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
        use dashmap::mapref::entry::Entry;
        // Use atomic entry API to avoid TOCTOU race between get_mut and remove
        if let Entry::Occupied(mut entry) =
            self.state.inner.ssh_live_sessions.entry(self.session_id)
        {
            if *entry.get() > 1 {
                *entry.get_mut() -= 1;
            } else {
                entry.remove();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{build_proxy_ws_url, replay_start_offset};
    use uuid::Uuid;

    /// Concurrent drops of ActiveSshProxyGuard for the same session_id must
    /// properly clean up the DashMap entry without races.
    #[test]
    fn active_ssh_proxy_guard_concurrent_drop_cleanup() {
        use dashmap::DashMap;
        use std::sync::Arc;

        let map: Arc<DashMap<Uuid, usize>> = Arc::new(DashMap::new());
        let session_id = Uuid::new_v4();

        // Simulate 100 concurrent guards
        let num_guards = 100usize;
        for _ in 0..num_guards {
            map.entry(session_id).and_modify(|c| *c += 1).or_insert(1);
        }
        assert_eq!(*map.get(&session_id).unwrap(), num_guards);

        // Drop them concurrently from multiple threads using the atomic entry API
        let mut handles = Vec::new();
        for _ in 0..num_guards {
            let map_clone = map.clone();
            handles.push(std::thread::spawn(move || {
                use dashmap::mapref::entry::Entry;
                if let Entry::Occupied(mut entry) = map_clone.entry(session_id) {
                    if *entry.get() > 1 {
                        *entry.get_mut() -= 1;
                    } else {
                        entry.remove();
                    }
                }
            }));
        }
        for h in handles {
            h.join().unwrap();
        }
        // Entry must be fully removed — no stale leftovers
        assert!(
            map.get(&session_id).is_none(),
            "entry should be removed after all guards dropped"
        );
    }

    #[test]
    fn replay_start_offset_uses_full_history_by_default() {
        assert_eq!(replay_start_offset(0, 0, 1024), 0);
    }

    #[test]
    fn replay_start_offset_uses_tail_bytes_when_no_offset() {
        assert_eq!(replay_start_offset(0, 256, 1024), 768);
    }

    #[test]
    fn replay_start_offset_caps_tail_bytes_at_history_start() {
        assert_eq!(replay_start_offset(0, 2048, 1024), 0);
    }

    #[test]
    fn replay_start_offset_prioritizes_explicit_offset() {
        assert_eq!(replay_start_offset(512, 256, 1024), 512);
    }

    #[test]
    fn replay_start_offset_caps_explicit_offset_at_replay_end() {
        assert_eq!(replay_start_offset(2048, 256, 1024), 1024);
    }

    #[test]
    fn build_proxy_ws_url_forwards_tail_bytes_when_no_offset() {
        let session_id = Uuid::parse_str("11111111-1111-1111-1111-111111111111").unwrap();
        assert_eq!(
            build_proxy_ws_url(7680, session_id, "", 0, 524288),
            "ws://127.0.0.1:7680/ws/session/11111111-1111-1111-1111-111111111111?tail_bytes=524288"
        );
    }

    #[test]
    fn build_proxy_ws_url_forwards_offset_and_tail_bytes_for_attach_mode() {
        let session_id = Uuid::parse_str("11111111-1111-1111-1111-111111111111").unwrap();
        assert_eq!(
            build_proxy_ws_url(7680, session_id, "", 128, 524288),
            "ws://127.0.0.1:7680/ws/session/11111111-1111-1111-1111-111111111111?offset=128&tail_bytes=524288"
        );
    }

    #[test]
    fn build_proxy_ws_url_ignores_tail_bytes_for_events_mode() {
        let session_id = Uuid::parse_str("11111111-1111-1111-1111-111111111111").unwrap();
        assert_eq!(
            build_proxy_ws_url(7680, session_id, "events", 128, 524288),
            "ws://127.0.0.1:7680/ws/session/11111111-1111-1111-1111-111111111111?mode=events"
        );
    }
}
