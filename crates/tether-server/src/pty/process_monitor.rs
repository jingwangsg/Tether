use crate::state::AppState;
use std::time::Duration;

/// Background task that polls foreground process for all alive sessions
/// every 2 seconds and broadcasts changes.
pub async fn run_process_monitor(state: AppState) {
    let mut interval = tokio::time::interval(Duration::from_secs(2));
    loop {
        interval.tick().await;

        for entry in state.inner.sessions.iter() {
            let session = entry.value();
            if !session.is_alive() {
                continue;
            }

            let new_fg = session.detect_foreground();
            let old_fg = session.get_foreground();

            if new_fg != old_fg {
                *session.foreground.lock().unwrap() = new_fg.clone();
                let _ = state.inner.fg_tx.send((session.id, new_fg));
            }
        }
    }
}
