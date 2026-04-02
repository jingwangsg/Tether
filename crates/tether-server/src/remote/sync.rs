use crate::persistence::store::{SessionRow, Store};

/// Fetch all sessions from the remote tether-server and insert any that are
/// missing from the local DB. Returns the number of sessions restored.
/// Idempotent: uses INSERT OR IGNORE so safe to call concurrently or repeatedly.
pub async fn sync_remote_sessions(
    db: &Store,
    host_alias: &str,
    tunnel_port: u16,
    local_group_id: &str,
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
        if db.try_insert_remote_session(&s.id, local_group_id, &s.name, &s.shell, &s.cwd)? {
            restored += 1;
            tracing::info!(
                "Restored remote session {} ({}) for host {}",
                s.name, s.id, host_alias
            );
        }
    }
    Ok(restored)
}
