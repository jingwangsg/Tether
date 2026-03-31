use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::Json;
use base64::Engine;
use serde::Deserialize;
use uuid::Uuid;

use crate::persistence::store::SessionRow;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct CreateSessionRequest {
    pub group_id: String,
    pub name: Option<String>,
    pub command: Option<String>,
    pub cwd: Option<String>,
}

/// Query params for POST /api/sessions
#[derive(Deserialize, Default)]
pub struct CreateSessionQuery {
    /// When local=true, store a DB record only — skip PTY spawn.
    /// Used by tether_ghostty where the client manages its own PTY via libghostty.
    #[serde(default)]
    pub local: bool,
}

#[derive(Deserialize)]
pub struct UpdateSessionRequest {
    pub name: Option<String>,
    pub sort_order: Option<i32>,
    pub group_id: Option<String>,
}

#[derive(Deserialize)]
pub struct ScrollbackQuery {
    #[serde(default)]
    pub offset: u64,
    #[serde(default = "default_limit")]
    pub limit: usize,
}

fn default_limit() -> usize {
    65536
}

pub async fn list_sessions(
    State(state): State<AppState>,
) -> Result<Json<Vec<SessionRow>>, StatusCode> {
    let mut rows = state
        .inner
        .db
        .list_sessions()
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    for row in &mut rows {
        if let Ok(id) = Uuid::parse_str(&row.id) {
            if let Some(session) = state.inner.sessions.get(&id) {
                row.is_alive = session.is_alive();
                let fg = session.get_foreground();
                row.foreground_process = fg.process;
            }
        }
    }

    Ok(Json(rows))
}

pub async fn create_session(
    State(state): State<AppState>,
    Query(query): Query<CreateSessionQuery>,
    Json(req): Json<CreateSessionRequest>,
) -> Result<(StatusCode, Json<SessionRow>), StatusCode> {
    let group_id =
        Uuid::parse_str(&req.group_id).map_err(|_| StatusCode::BAD_REQUEST)?;

    if query.local {
        // local=true: store DB record only, skip PTY spawn.
        // tether_ghostty manages its own PTY via libghostty.
        let id = Uuid::new_v4();
        let session_name = req.name.unwrap_or_else(|| format!("session-{}", &id.to_string()[..8]));
        let shell = req.command.unwrap_or_default();
        let cwd = req.cwd.unwrap_or_else(|| "~".to_string());

        let row = state
            .inner
            .db
            .create_session(
                &id.to_string(),
                &group_id.to_string(),
                &session_name,
                &shell,
                &cwd,
            )
            .map_err(|e| {
                tracing::error!("Failed to create local session record: {}", e);
                StatusCode::INTERNAL_SERVER_ERROR
            })?;

        // Return with is_alive=false since there's no server-side PTY
        let mut response_row = row;
        response_row.is_alive = false;

        tracing::info!("Created local session record {} ({})", session_name, id);
        return Ok((StatusCode::CREATED, Json(response_row)));
    }

    // Normal path: spawn PTY session
    let session = state
        .create_session(group_id, req.name, req.command, req.cwd)
        .map_err(|e| {
            tracing::error!("Failed to create session: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    let row = SessionRow {
        id: session.id.to_string(),
        group_id: session.get_group_id().to_string(),
        name: session.get_name(),
        shell: session.shell.clone(),
        cols: session.cols.load(std::sync::atomic::Ordering::Relaxed),
        rows: session.rows.load(std::sync::atomic::Ordering::Relaxed),
        cwd: session.cwd.clone(),
        created_at: chrono::Utc::now().to_rfc3339(),
        last_active: chrono::Utc::now().to_rfc3339(),
        is_alive: session.is_alive(),
        foreground_process: None,
    };

    Ok((StatusCode::CREATED, Json(row)))
}

pub async fn update_session(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(req): Json<UpdateSessionRequest>,
) -> StatusCode {
    if let Some(name) = &req.name {
        if let Ok(uuid) = Uuid::parse_str(&id) {
            if let Some(session) = state.inner.sessions.get(&uuid) {
                session.set_name(name);
            }
        }
        state.inner.db.update_session_name(&id, name).ok();
    }
    if let Some(order) = req.sort_order {
        state.inner.db.update_session_sort_order(&id, order).ok();
    }
    if let Some(ref group_id) = req.group_id {
        state.inner.db.update_session_group(&id, group_id).ok();
        if let Ok(uuid) = Uuid::parse_str(&id) {
            if let Ok(new_gid) = Uuid::parse_str(group_id) {
                if let Some(session) = state.inner.sessions.get(&uuid) {
                    session.set_group_id(new_gid);
                }
            }
        }
    }
    StatusCode::OK
}

pub async fn delete_session(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> StatusCode {
    match Uuid::parse_str(&id) {
        Ok(uuid) => match state.kill_session(uuid) {
            Ok(_) => StatusCode::OK,
            Err(_) => StatusCode::INTERNAL_SERVER_ERROR,
        },
        Err(_) => StatusCode::BAD_REQUEST,
    }
}

pub async fn batch_reorder_sessions(
    State(state): State<AppState>,
    Json(items): Json<Vec<super::groups::ReorderItem>>,
) -> StatusCode {
    let orders: Vec<(String, i32)> = items.into_iter().map(|i| (i.id, i.sort_order)).collect();
    match state.inner.db.batch_reorder_sessions(&orders) {
        Ok(_) => StatusCode::OK,
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

pub async fn get_scrollback(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<ScrollbackQuery>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let uuid = Uuid::parse_str(&id).map_err(|_| StatusCode::BAD_REQUEST)?;
    let session = state
        .get_session(uuid)
        .ok_or(StatusCode::NOT_FOUND)?;

    let data = session
        .scrollback
        .lock()
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .read_disk(query.offset, query.limit)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let b64 = base64::engine::general_purpose::STANDARD;
    Ok(Json(serde_json::json!({
        "data": b64.encode(&data),
        "offset": query.offset,
        "length": data.len(),
    })))
}
