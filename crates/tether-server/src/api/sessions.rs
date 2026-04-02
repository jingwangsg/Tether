use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::Json;
use base64::Engine;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::persistence::store::SessionRow;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct CreateSessionRequest {
    pub group_id: String,
    pub name: Option<String>,
    pub command: Option<String>,
    pub cwd: Option<String>,
    /// Optional explicit session ID; used internally when local server creates a
    /// session on a remote tether-server so both sides share the same UUID.
    pub id: Option<Uuid>,
}

/// Body sent from local tether-server → remote tether-server when proxying session creation.
#[derive(Serialize)]
struct RemoteCreateRequest {
    pub group_id: String,
    pub name: Option<String>,
    pub command: Option<String>,
    pub cwd: Option<String>,
    pub id: Option<Uuid>,
}

/// Query params for POST /api/sessions
#[derive(Deserialize, Default)]
pub struct CreateSessionQuery {
    /// When local=true, store a DB record only — skip PTY spawn.
    /// Used by the native macOS client which manages its own PTY locally.
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
                // Local PTY session — use live foreground detection.
                row.is_alive = session.is_alive();
                let fg = session.get_foreground();
                row.foreground_process = fg.process;
            } else if let Some(fg) = state.inner.ssh_fg.get(&id) {
                // SSH-proxied session — return cached foreground from last sync/proxy.
                row.foreground_process = Some(fg.clone());
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
        // Native macOS client manages its own PTY locally.
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

    // Check if this group uses a remote SSH host
    if let Ok(Some(ssh_host)) = state.inner.db.get_group_ssh_host(&group_id.to_string()) {
        return create_remote_session(&state, group_id, req, &ssh_host).await;
    }

    // Normal path: spawn PTY session
    let session = state
        .create_session(group_id, req.name, req.command, req.cwd, req.id)
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
    // Proxy to remote if this is a remote session
    if let Ok(Some(ssh_host)) = state.inner.db.get_session_ssh_host(&id) {
        if let Some(port) = state.inner.remote_manager.get_tunnel_port(&ssh_host) {
            let url = format!("http://127.0.0.1:{}/api/sessions/{}", port, id);
            let _ = reqwest::Client::new().delete(&url).send().await;
        }
        // Always remove local DB record regardless of remote result
        state.inner.db.delete_session(&id).ok();
        return StatusCode::OK;
    }

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
    // Proxy to remote if this is a remote session
    if let Ok(Some(ssh_host)) = state.inner.db.get_session_ssh_host(&id) {
        if let Some(port) = state.inner.remote_manager.get_tunnel_port(&ssh_host) {
            let url = format!(
                "http://127.0.0.1:{}/api/sessions/{}/scrollback?offset={}&limit={}",
                port, id, query.offset, query.limit
            );
            let resp = reqwest::Client::new()
                .get(&url)
                .send()
                .await
                .map_err(|_| StatusCode::BAD_GATEWAY)?
                .json::<serde_json::Value>()
                .await
                .map_err(|_| StatusCode::BAD_GATEWAY)?;
            return Ok(Json(resp));
        }
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }

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

/// Forward session creation to the remote tether-server via the SSH tunnel.
async fn create_remote_session(
    state: &AppState,
    group_id: Uuid,
    req: CreateSessionRequest,
    ssh_host: &str,
) -> Result<(StatusCode, Json<SessionRow>), StatusCode> {
    let port = match state.inner.remote_manager.get_tunnel_port(ssh_host) {
        Some(p) => p,
        None => {
            // Host not Ready — kick off a background connect attempt so a
            // client retry in a few seconds succeeds instead of waiting for
            // the 60-second scanner cycle.
            state.inner.remote_manager.trigger_connect_if_needed(ssh_host);
            return Err(StatusCode::SERVICE_UNAVAILABLE);
        }
    };

    // Use the group that was created on the remote server, not the local group ID
    let remote_group_id = state
        .inner
        .remote_manager
        .get_remote_group_id(ssh_host)
        .ok_or(StatusCode::SERVICE_UNAVAILABLE)?;

    // Allocate the UUID here so both local DB and remote use the same ID
    let id = req.id.unwrap_or_else(Uuid::new_v4);

    // Strip transport SSH commands: "ssh <host>" was used locally to reach this
    // remote, but we are already on the remote — let it run its default shell.
    let remote_command = req.command.as_deref()
        .filter(|cmd| !cmd.trim_start().starts_with("ssh "))
        .map(|s| s.to_string());

    let body = RemoteCreateRequest {
        group_id: remote_group_id,
        name: req.name.clone(),
        command: remote_command,
        cwd: req.cwd.clone(),
        id: Some(id),
    };

    // Verify the tunnel port is still alive before attempting the HTTP POST.
    // If dead, clear the stale Ready state immediately so the scanner reconnects
    // on its next cycle, and return 503 instead of letting reqwest fail with 502.
    if tokio::net::TcpStream::connect(("127.0.0.1", port)).await.is_err() {
        state.inner.remote_manager.clear_dead_tunnel(ssh_host);
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }

    let http_resp = reqwest::Client::new()
        .post(format!("http://127.0.0.1:{}/api/sessions", port))
        .json(&body)
        .send()
        .await
        .map_err(|e| {
            tracing::error!("Remote session POST failed: {}", e);
            StatusCode::BAD_GATEWAY
        })?;

    if !http_resp.status().is_success() {
        let remote_status = http_resp.status();
        let body_text = http_resp.text().await.unwrap_or_default();
        tracing::error!("Remote server returned {}: {}", remote_status, body_text);
        return Err(StatusCode::BAD_GATEWAY);
    }

    let remote_row: SessionRow = http_resp.json().await.map_err(|e| {
        tracing::error!("Failed to parse remote session response: {}", e);
        StatusCode::BAD_GATEWAY
    })?;

    // Store metadata in local DB so we can route future requests
    state
        .inner
        .db
        .create_session(
            &id.to_string(),
            &group_id.to_string(),
            &remote_row.name,
            &remote_row.shell,
            &remote_row.cwd,
        )
        .map_err(|e| {
            tracing::error!("Failed to store remote session in local DB: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    Ok((StatusCode::CREATED, Json(remote_row)))
}
