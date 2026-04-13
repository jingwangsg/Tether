use crate::pty::session::{PtySession, ToolStatus};
use crate::state::AppState;
use std::sync::Arc;
use std::time::Duration;
use uuid::Uuid;

/// Run the full update sequence for a single session: alt-screen cache
/// maintenance, detect_foreground, publish.
fn full_session_update(state: &AppState, session: &Arc<PtySession>, source_label: &str) {
    let old_fg = session.get_foreground();
    let old_tool_status = PtySession::derive_tool_status(&old_fg);
    let mut new_fg = session.detect_foreground();
    let new_tool_status = PtySession::derive_tool_status(&new_fg);
    let in_alt = session.is_in_alternate_screen();
    if PtySession::is_known_tool(new_fg.process.as_deref()) && in_alt {
        session.set_last_detected_alt_screen_tool(new_fg.process.clone());
    } else if !in_alt && !PtySession::is_known_tool(new_fg.process.as_deref()) {
        session.set_last_detected_alt_screen_tool(None);
    }

    let mut attention_state = session.tool_attention_state();
    if new_tool_status == ToolStatus::Running {
        if attention_state.status != ToolStatus::Running {
            attention_state.running_since = Some(std::time::Instant::now());
        }
        if old_fg.has_attention() {
            match state
                .inner
                .db
                .set_session_attention_ack_seq(&session.id.to_string(), old_fg.attention_seq)
            {
                Ok(_) => new_fg.attention_ack_seq = old_fg.attention_seq,
                Err(error) => tracing::warn!(
                    session_id = %session.id,
                    source = source_label,
                    "failed to clear attention on command restart: {error}"
                ),
            }
        }
    } else {
        if old_tool_status == ToolStatus::Running
            && new_tool_status == ToolStatus::Waiting
            && attention_state
                .running_since
                .map(|running_since| running_since.elapsed() > Duration::from_secs(5))
                .unwrap_or(false)
        {
            match state
                .inner
                .db
                .increment_session_attention_seq(&session.id.to_string())
            {
                Ok(Some(next_seq)) => {
                    new_fg.attention_seq = next_seq;
                }
                Ok(None) => {}
                Err(error) => tracing::warn!(
                    session_id = %session.id,
                    source = source_label,
                    "failed to mark session attention: {error}"
                ),
            }
        }
        attention_state.running_since = None;
    }
    attention_state.status = new_tool_status;
    session.set_tool_attention_state(attention_state);

    if new_fg != old_fg {
        if PtySession::is_known_tool(old_fg.process.as_deref())
            || PtySession::is_known_tool(new_fg.process.as_deref())
        {
            tracing::debug!(
                target: "tool-state",
                session_id = %session.id,
                source = source_label,
                old_process = ?old_fg.process,
                new_process = ?new_fg.process,
                old_attention_seq = old_fg.attention_seq,
                new_attention_seq = new_fg.attention_seq,
                old_attention_ack_seq = old_fg.attention_ack_seq,
                new_attention_ack_seq = new_fg.attention_ack_seq,
                in_alt,
                "foreground changed"
            );
        }
        *session.foreground.lock().unwrap() = new_fg.clone();
        state.publish_session_status(session.id);
    }
}

/// Background task that polls foreground process for all alive sessions.
/// - Slow path (every 2s): full detection including `ps` syscall.
/// - Notification path: immediate re-evaluation triggered by semantic prompt events.
pub async fn run_process_monitor(
    state: AppState,
    mut semantic_event_rx: tokio::sync::mpsc::Receiver<Uuid>,
) {
    let mut slow_interval = tokio::time::interval(Duration::from_secs(2));
    loop {
        tokio::select! {
            _ = slow_interval.tick() => {
                for entry in state.inner.sessions.iter() {
                    let session = entry.value();
                    if !session.is_alive() { continue; }
                    full_session_update(&state, session, "process_monitor_slow");
                }
            }
            Some(session_id) = semantic_event_rx.recv() => {
                if let Some(session) = state.inner.sessions.get(&session_id) {
                    let session = session.value();
                    if session.is_alive() {
                        full_session_update(&state, session, "semantic_notification");
                    }
                }
            }
        }
    }
}
