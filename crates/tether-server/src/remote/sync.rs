use crate::persistence::store::{SessionRow, Store};
use dashmap::DashMap;
use uuid::Uuid;

/// Fetch all sessions from the remote tether-server and insert any that are
/// missing from the local DB. Returns the number of sessions restored.
/// Idempotent: uses INSERT OR IGNORE so safe to call concurrently or repeatedly.
/// Also updates `ssh_fg` with the foreground state reported by the remote server.
pub async fn sync_remote_sessions(
    db: &Store,
    host_alias: &str,
    tunnel_port: u16,
    local_group_id: &str,
    ssh_fg: &DashMap<Uuid, String>,
) -> anyhow::Result<usize> {
    let url = format!("http://127.0.0.1:{}/api/sessions", tunnel_port);
    let remote_sessions: Vec<SessionRow> = reqwest::Client::new()
        .get(&url)
        .send()
        .await?
        .json()
        .await?;

    let mut restored = 0usize;
    for s in &remote_sessions {
        if db.try_insert_remote_session(&s.id, local_group_id, s.local_group_id.as_deref(), &s.name, &s.shell, &s.cwd)? {
            restored += 1;
            tracing::info!(
                "Restored remote session {} ({}) for host {}",
                s.name, s.id, host_alias
            );
        }
        // Update fg cache regardless of whether the session was newly inserted.
        if let Ok(id) = Uuid::parse_str(&s.id) {
            match &s.foreground_process {
                Some(fp) => { ssh_fg.insert(id, fp.clone()); }
                None => { ssh_fg.remove(&id); }
            }
        }
    }
    Ok(restored)
}
