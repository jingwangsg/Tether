use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;

use crate::persistence::store::GroupRow;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct CreateGroupRequest {
    pub name: String,
    #[serde(default = "default_cwd")]
    pub default_cwd: String,
    pub parent_id: Option<String>,
    pub ssh_host: Option<String>,
}

fn default_cwd() -> String {
    "~".to_string()
}

#[derive(Deserialize)]
pub struct UpdateGroupRequest {
    pub name: Option<String>,
    pub default_cwd: Option<String>,
    pub sort_order: Option<i32>,
    pub ssh_host: Option<String>,
}

#[derive(Deserialize)]
pub struct ReorderItem {
    pub id: String,
    pub sort_order: i32,
}

pub async fn list_groups(State(state): State<AppState>) -> Result<Json<Vec<GroupRow>>, StatusCode> {
    state
        .inner
        .db
        .list_groups()
        .map(Json)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}

pub async fn create_group(
    State(state): State<AppState>,
    Json(req): Json<CreateGroupRequest>,
) -> Result<(StatusCode, Json<GroupRow>), StatusCode> {
    // Cycle detection: if parent_id is set, verify it doesn't create a cycle
    // (For new groups this is a no-op since the group doesn't exist yet,
    //  but we validate parent_id actually exists)
    if let Some(ref parent_id) = req.parent_id {
        if state
            .inner
            .db
            .get_group(parent_id)
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
            .is_none()
        {
            return Err(StatusCode::BAD_REQUEST);
        }
    }

    state
        .inner
        .db
        .create_group(
            &req.name,
            &req.default_cwd,
            req.parent_id.as_deref(),
            req.ssh_host.as_deref(),
        )
        .map(|g| (StatusCode::CREATED, Json(g)))
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}

pub async fn update_group(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(req): Json<UpdateGroupRequest>,
) -> StatusCode {
    match state.inner.db.update_group(
        &id,
        req.name.as_deref(),
        req.default_cwd.as_deref(),
        req.sort_order,
        req.ssh_host.as_deref(),
    ) {
        Ok(_) => StatusCode::OK,
        Err(e) if e.to_string().contains("not_found") => StatusCode::NOT_FOUND,
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

pub async fn delete_group(State(state): State<AppState>, Path(id): Path<String>) -> StatusCode {
    // Collect all descendant group IDs (recursive)
    let group_ids = match state.inner.db.collect_descendant_ids(&id) {
        Ok(ids) => ids,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR,
    };

    // Kill all in-memory sessions belonging to any of these groups
    let sessions_to_kill: Vec<_> = state
        .inner
        .sessions
        .iter()
        .filter(|s| group_ids.contains(&s.get_group_id().to_string()))
        .map(|s| s.id)
        .collect();

    for sid in sessions_to_kill {
        state.kill_session(sid).ok();
    }

    // Best-effort: proxy DELETE to remote for any SSH-backed sessions in these groups.
    // Unlike individual session DELETE (which returns 503 when the tunnel is down),
    // group deletion always cleans up locally — blocking an entire group delete on a
    // tunnel outage would leave the user with an unusable local sidebar entry.
    if let Ok(db_sessions) = state.inner.db.get_sessions_in_groups(&group_ids) {
        for s in db_sessions {
            if let Ok(Some(host)) = state.inner.db.get_session_ssh_host(&s.id) {
                if let Some(port) = state.inner.remote_manager.get_tunnel_port(&host) {
                    let url = format!("http://127.0.0.1:{}/api/sessions/{}", port, s.id);
                    let _ = reqwest::Client::new().delete(&url).send().await;
                }
            }
        }
    }

    // Delete group and all descendants from DB (wrapped in transaction)
    match state.inner.db.delete_group(&id) {
        Ok(_) => StatusCode::OK,
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

pub async fn batch_reorder_groups(
    State(state): State<AppState>,
    Json(items): Json<Vec<ReorderItem>>,
) -> StatusCode {
    let orders: Vec<(String, i32)> = items.into_iter().map(|i| (i.id, i.sort_order)).collect();
    match state.inner.db.batch_reorder_groups(&orders) {
        Ok(_) => StatusCode::OK,
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR,
    }
}
