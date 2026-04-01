use crate::pty::session::{PtySession, SessionForeground};
use crate::state::AppState;
use std::time::Duration;

/// Background task that polls foreground process for all alive sessions.
/// - Slow path (every 2s): full detection including `ps` syscall.
/// - Fast path (every 250ms): lightweight tool-state update from in-memory timestamp only.
pub async fn run_process_monitor(state: AppState) {
    let mut slow_interval = tokio::time::interval(Duration::from_secs(2));
    let mut fast_interval = tokio::time::interval(Duration::from_millis(250));
    loop {
        tokio::select! {
            _ = slow_interval.tick() => {
                for entry in state.inner.sessions.iter() {
                    let session = entry.value();
                    if !session.is_alive() { continue; }
                    let new_fg = session.detect_foreground();
                    // Maintain the persistent alt-screen cache.
                    // When active, the cache is populated from ps/OSC/output detection.
                    // When idle, detect_foreground_process() falls back to the cache itself,
                    // so new_fg.process may originate from the cache — writing it back is
                    // intentional and keeps the cache alive through idle periods.
                    // The cache is cleared when we are confirmed outside alt-screen with no tool.
                    let in_alt = session.is_in_alternate_screen();
                    if PtySession::is_known_tool(new_fg.process.as_deref()) && in_alt {
                        session.set_last_detected_alt_screen_tool(new_fg.process.clone());
                    } else if !in_alt && !PtySession::is_known_tool(new_fg.process.as_deref()) {
                        session.set_last_detected_alt_screen_tool(None);
                    }
                    let old_fg = session.get_foreground();
                    if new_fg != old_fg {
                        *session.foreground.lock().unwrap() = new_fg.clone();
                        let _ = state.inner.fg_tx.send((session.id, new_fg));
                    }
                }
            }
            _ = fast_interval.tick() => {
                for entry in state.inner.sessions.iter() {
                    let session = entry.value();
                    if !session.is_alive() { continue; }
                    let old_fg = session.get_foreground();
                    if !PtySession::is_known_tool(old_fg.process.as_deref()) { continue; }
                    let tool_state = session.compute_tool_state();
                    if tool_state != old_fg.tool_state {
                        let new_fg = SessionForeground {
                            process: old_fg.process.clone(),
                            tool_state,
                        };
                        *session.foreground.lock().unwrap() = new_fg.clone();
                        let _ = state.inner.fg_tx.send((session.id, new_fg));
                    }
                }
            }
        }
    }
}
