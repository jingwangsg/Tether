use crate::config::ServerConfig;
use crate::persistence::Store;
use crate::pty::session::{PtySession, SessionForeground};
use crate::remote::manager::RemoteManager;
use dashmap::DashMap;
use std::sync::Arc;
use tokio::sync::broadcast;
use uuid::Uuid;

pub type SessionId = Uuid;
#[derive(Clone)]
pub struct AppState {
    pub inner: Arc<AppStateInner>,
}

pub struct AppStateInner {
    pub config: ServerConfig,
    pub sessions: DashMap<SessionId, Arc<PtySession>>,
    pub db: Store,
    pub shutdown_tx: broadcast::Sender<()>,
    /// Broadcast the latest session foreground per session.
    pub status_tx: broadcast::Sender<(Uuid, SessionForeground)>,
    pub remote_manager: RemoteManager,
    /// Cached foreground process for SSH-proxied sessions.
    /// Transient (not persisted). Updated by sync_remote_sessions and proxy_ws_to_remote.
    pub ssh_fg: DashMap<Uuid, SessionForeground>,
    /// Number of active proxied SSH WebSocket clients per session. While a live
    /// proxy exists, its foreground updates are more authoritative than periodic
    /// HTTP sync snapshots.
    pub ssh_live_sessions: DashMap<Uuid, usize>,
    /// Channel sender for semantic prompt events (session_id).
    /// Shared with all PtySession instances; the receiver goes to process_monitor.
    /// Bounded to prevent unbounded memory growth; excess events are dropped via try_send.
    pub semantic_event_tx: tokio::sync::mpsc::Sender<Uuid>,
    /// Receiver for semantic prompt events, taken once by the process monitor.
    pub semantic_event_rx: std::sync::Mutex<Option<tokio::sync::mpsc::Receiver<Uuid>>>,
}

impl AppState {
    #[allow(dead_code)]
    pub async fn new(config: ServerConfig) -> anyhow::Result<Self> {
        Self::new_with_remote_policy(config, false).await
    }

    pub async fn new_with_remote_policy(
        config: ServerConfig,
        allow_remote_mutation: bool,
    ) -> anyhow::Result<Self> {
        let data_dir = config.data_dir();
        std::fs::create_dir_all(&data_dir)?;
        config.materialize_terminal_runtime()?;

        let db_path = format!("{}/tether.db", data_dir);
        let db = Store::new(&db_path)?;
        db.init_tables()?;

        let (shutdown_tx, _) = broadcast::channel(1);
        let (status_tx, _) = broadcast::channel(64);
        let (semantic_event_tx, semantic_event_rx) = tokio::sync::mpsc::channel(1024);

        Ok(Self {
            inner: Arc::new(AppStateInner {
                config,
                sessions: DashMap::new(),
                db,
                shutdown_tx,
                status_tx,
                remote_manager: RemoteManager::new_with_deploy(allow_remote_mutation),
                ssh_fg: DashMap::new(),
                ssh_live_sessions: DashMap::new(),
                semantic_event_tx,
                semantic_event_rx: std::sync::Mutex::new(Some(semantic_event_rx)),
            }),
        })
    }

    pub fn publish_session_status(&self, session_id: Uuid) {
        let foreground = if let Some(session) = self.get_session(session_id) {
            session.get_foreground()
        } else if let Some(fg) = self.inner.ssh_fg.get(&session_id) {
            fg.clone()
        } else {
            SessionForeground::default()
        };

        let _ = self.inner.status_tx.send((session_id, foreground));
    }
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    /// Bounded semantic event channel with try_send drops excess messages
    /// instead of growing without limit.
    #[test]
    fn bounded_semantic_event_channel_drops_excess() {
        let (tx, _rx) = tokio::sync::mpsc::channel::<Uuid>(1024);
        let mut sent = 0usize;
        for _ in 0..2000 {
            match tx.try_send(Uuid::new_v4()) {
                Ok(_) => sent += 1,
                Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => break,
                Err(e) => panic!("unexpected error: {:?}", e),
            }
        }
        assert_eq!(sent, 1024, "bounded channel should cap at its capacity");
    }

    /// Unbounded channel grows without limit (the old behavior we're fixing).
    #[test]
    fn unbounded_semantic_event_channel_grows_without_limit() {
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel::<Uuid>();
        for _ in 0..5000 {
            tx.send(Uuid::new_v4()).unwrap();
        }
        // All 5000 messages accepted — no backpressure, unbounded memory growth
    }
}
