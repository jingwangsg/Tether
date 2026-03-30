use crate::config::ServerConfig;
use crate::persistence::Store;
use crate::pty::session::{PtySession, SessionForeground};
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
}

impl AppState {
    pub async fn new(config: ServerConfig) -> anyhow::Result<Self> {
        let data_dir = config.data_dir();
        std::fs::create_dir_all(&data_dir)?;

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
            }),
        })
    }
}
