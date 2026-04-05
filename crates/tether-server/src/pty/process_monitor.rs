use crate::pty::session::PtySession;
use crate::state::AppState;
use std::sync::Arc;
use std::time::Duration;
use uuid::Uuid;

/// Run the full update sequence for a single session: alt-screen cache
/// maintenance, detect_foreground, publish.
fn full_session_update(state: &AppState, session: &Arc<PtySession>, source_label: &str) {
    let new_fg = session.detect_foreground();
    let in_alt = session.is_in_alternate_screen();
    if PtySession::is_known_tool(new_fg.process.as_deref()) && in_alt {
        session.set_last_detected_alt_screen_tool(new_fg.process.clone());
    } else if !in_alt && !PtySession::is_known_tool(new_fg.process.as_deref()) {
        session.set_last_detected_alt_screen_tool(None);
    }
    let old_fg = session.get_foreground();
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
    mut semantic_event_rx: tokio::sync::mpsc::UnboundedReceiver<Uuid>,
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
