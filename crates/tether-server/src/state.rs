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
    /// Broadcast foreground process changes per session
    pub fg_tx: broadcast::Sender<(Uuid, SessionForeground)>,
    pub remote_manager: RemoteManager,
    /// Cached foreground process for SSH-proxied sessions.
    /// Transient (not persisted). Updated by sync_remote_sessions and proxy_ws_to_remote.
    pub ssh_fg: DashMap<Uuid, SessionForeground>,
    /// Number of active proxied SSH WebSocket clients per session. While a live
    /// proxy exists, its foreground updates are more authoritative than periodic
    /// HTTP sync snapshots.
    pub ssh_live_sessions: DashMap<Uuid, usize>,
}

impl AppState {
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
        let (fg_tx, _) = broadcast::channel(64);

        Ok(Self {
            inner: Arc::new(AppStateInner {
                config,
                sessions: DashMap::new(),
                db,
                shutdown_tx,
                fg_tx,
                remote_manager: RemoteManager::new_with_deploy(allow_remote_mutation),
                ssh_fg: DashMap::new(),
                ssh_live_sessions: DashMap::new(),
            }),
        })
    }
}
