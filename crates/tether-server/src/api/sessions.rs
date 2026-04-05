use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::Json;
use base64::Engine;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::persistence::store::{GroupRow, SessionRow};
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
    /// Legacy field retained for compatibility with older remote daemons.
    pub local_group_id: Option<String>,
}

#[derive(Serialize)]
struct RemoteCreateRequest {
    pub group_id: String,
    pub name: Option<String>,
    pub command: Option<String>,
    pub cwd: Option<String>,
    pub id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub local_group_id: Option<String>,
}

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
    /// Legacy field retained for compatibility with older remote daemons.
    pub local_group_id: Option<String>,
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
                row.osc_title = fg.osc_title;
            } else if let Some(fg) = state.inner.ssh_fg.get(&id) {
                row.foreground_process = fg.process.clone();
                row.osc_title = fg.osc_title.clone();
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
    let group = state
        .inner
        .db
        .get_group(&req.group_id)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .ok_or(StatusCode::BAD_REQUEST)?;
    let group_id = Uuid::parse_str(&group.id).map_err(|_| StatusCode::BAD_REQUEST)?;

    if query.local {
        if group.ssh_host.is_some() {
            return Err(StatusCode::BAD_REQUEST);
        }
        let id = Uuid::new_v4();
        let session_name = req
            .name
            .unwrap_or_else(|| format!("session-{}", &id.to_string()[..8]));
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
                req.local_group_id.as_deref(),
            )
            .map_err(|e| {
                tracing::error!("Failed to create local session record: {}", e);
                StatusCode::INTERNAL_SERVER_ERROR
            })?;

        let mut response_row = row;
        response_row.is_alive = false;
        tracing::info!("Created local session record {} ({})", session_name, id);
        return Ok((StatusCode::CREATED, Json(response_row)));
    }

    if let Some(ssh_host) = group.ssh_host.as_deref() {
        return create_remote_session(&state, &group, req, ssh_host).await;
    }

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
        sort_order: 0,
        is_alive: session.is_alive(),
        foreground_process: None,
        osc_title: None,
        local_group_id: None,
    };

    Ok((StatusCode::CREATED, Json(row)))
}

pub async fn update_session(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(req): Json<UpdateSessionRequest>,
) -> StatusCode {
    let current = match state.inner.db.get_session(&id) {
        Ok(Some(session)) => session,
        Ok(None) => return StatusCode::NOT_FOUND,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR,
    };
    let original_ssh_host = match state.inner.db.get_session_ssh_host(&id) {
        Ok(host) => host,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR,
    };
    let target_group_host = match validate_requested_group(
        &state,
        original_ssh_host.as_deref(),
        req.group_id.as_deref(),
    ) {
        Ok(host) => host,
        Err(status) => return status,
    };

    if let Some(host_alias) = original_ssh_host.as_deref() {
        if target_group_host.as_deref() != Some(host_alias) {
            return StatusCode::BAD_REQUEST;
        }
        let port = match ready_tunnel_port(&state, host_alias) {
            Ok(port) => port,
            Err(status) => return status,
        };
        let mut patch = serde_json::Map::new();
        if let Some(ref name) = req.name {
            patch.insert("name".into(), serde_json::Value::String(name.clone()));
        }
        if let Some(order) = req.sort_order {
            patch.insert("sort_order".into(), serde_json::Value::Number(order.into()));
        }
        if let Some(ref group_id) = req.group_id {
            patch.insert(
                "group_id".into(),
                serde_json::Value::String(group_id.clone()),
            );
        }
        if let Some(ref legacy_group_id) = req.local_group_id {
            patch.insert(
                "local_group_id".into(),
                serde_json::Value::String(legacy_group_id.clone()),
            );
        }

        let response = match reqwest::Client::new()
            .patch(format!("http://127.0.0.1:{port}/api/sessions/{id}"))
            .json(&serde_json::Value::Object(patch))
            .send()
            .await
        {
            Ok(response) => response,
            Err(_) => return StatusCode::BAD_GATEWAY,
        };
        if !response.status().is_success() {
            return StatusCode::BAD_GATEWAY;
        }
        if let Some(name) = &req.name {
            if let Err(error) = state.inner.db.update_session_name(&id, name) {
                tracing::warn!(
                    "Remote session update mirror name refresh failed for {} on {}: {}",
                    id,
                    host_alias,
                    error
                );
            }
        }
        if let Some(order) = req.sort_order {
            if let Err(error) = state.inner.db.update_session_sort_order(&id, order) {
                tracing::warn!(
                    "Remote session update mirror reorder failed for {} on {}: {}",
                    id,
                    host_alias,
                    error
                );
            }
        }
        if let Some(group_id) = req.group_id.as_deref() {
            if let Err(error) = state.inner.db.update_session_group(&id, group_id) {
                tracing::warn!(
                    "Remote session update mirror move failed for {} on {}: {}",
                    id,
                    host_alias,
                    error
                );
            }
        }
        best_effort_sync_remote_host(&state, host_alias, port, "session update");
        return StatusCode::OK;
    }

    if target_group_host.is_some() {
        return StatusCode::BAD_REQUEST;
    }

    if let Some(name) = &req.name {
        if let Ok(uuid) = Uuid::parse_str(&id) {
            if let Some(session) = state.inner.sessions.get(&uuid) {
                session.set_name(name);
            }
        }
        match state.inner.db.update_session_name(&id, name) {
            Ok(0) => return StatusCode::NOT_FOUND,
            Err(_) => return StatusCode::INTERNAL_SERVER_ERROR,
            _ => {}
        }
    }
    if let Some(order) = req.sort_order {
        match state.inner.db.update_session_sort_order(&id, order) {
            Ok(0) => return StatusCode::NOT_FOUND,
            Err(_) => return StatusCode::INTERNAL_SERVER_ERROR,
            _ => {}
        }
    }
    if let Some(ref group_id) = req.group_id {
        match state.inner.db.update_session_group(&id, group_id) {
            Ok(0) => return StatusCode::NOT_FOUND,
            Err(_) => return StatusCode::INTERNAL_SERVER_ERROR,
            Ok(_) => {
                if let Ok(uuid) = Uuid::parse_str(&id) {
                    if let Ok(new_gid) = Uuid::parse_str(group_id) {
                        if let Some(session) = state.inner.sessions.get(&uuid) {
                            session.set_group_id(new_gid);
                        }
                    }
                }
            }
        }
    }

    if req.local_group_id.is_some() && current.local_group_id != req.local_group_id {
        return StatusCode::BAD_REQUEST;
    }

    StatusCode::OK
}

pub async fn delete_session(State(state): State<AppState>, Path(id): Path<String>) -> StatusCode {
    let ssh_host = match state.inner.db.get_session_ssh_host(&id) {
        Ok(host) => host,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR,
    };

    if let Some(host_alias) = ssh_host.as_deref() {
        let port = match ready_tunnel_port(&state, host_alias) {
            Ok(port) => port,
            Err(status) => return status,
        };
        let response = match reqwest::Client::new()
            .delete(format!("http://127.0.0.1:{port}/api/sessions/{id}"))
            .send()
            .await
        {
            Ok(response) => response,
            Err(_) => return StatusCode::BAD_GATEWAY,
        };
        if !response.status().is_success() {
            return StatusCode::BAD_GATEWAY;
        }
        state.inner.db.delete_session(&id).ok();
        if let Ok(uuid) = Uuid::parse_str(&id) {
            state.inner.ssh_fg.remove(&uuid);
        }
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

#[derive(Deserialize, Serialize)]
pub struct SessionReorderItem {
    pub id: String,
    pub sort_order: i32,
    /// When present, moves the session to this group in the same operation.
    pub group_id: Option<String>,
}

pub async fn batch_reorder_sessions(
    State(state): State<AppState>,
    Json(items): Json<Vec<SessionReorderItem>>,
) -> StatusCode {
    if items.is_empty() {
        return StatusCode::OK;
    }

    let mut scope_host: Option<Option<String>> = None;
    for item in &items {
        let current_host = match state.inner.db.get_session_ssh_host(&item.id) {
            Ok(host) => host,
            Err(_) => return StatusCode::INTERNAL_SERVER_ERROR,
        };
        let target_host = match validate_requested_group(
            &state,
            current_host.as_deref(),
            item.group_id.as_deref(),
        ) {
            Ok(host) => host,
            Err(status) => return status,
        };
        if current_host != target_host {
            return StatusCode::BAD_REQUEST;
        }
        match &scope_host {
            Some(scope) if *scope != current_host => return StatusCode::BAD_REQUEST,
            None => scope_host = Some(current_host),
            _ => {}
        }
    }

    if let Some(Some(host_alias)) = scope_host {
        let port = match ready_tunnel_port(&state, &host_alias) {
            Ok(port) => port,
            Err(status) => return status,
        };
        let response = match reqwest::Client::new()
            .post(format!("http://127.0.0.1:{port}/api/sessions/reorder"))
            .json(&items)
            .send()
            .await
        {
            Ok(response) => response,
            Err(_) => return StatusCode::BAD_GATEWAY,
        };
        if !response.status().is_success() {
            return StatusCode::BAD_GATEWAY;
        }
        let orders = items
            .iter()
            .map(|item| (item.id.clone(), item.sort_order, item.group_id.clone()))
            .collect::<Vec<_>>();
        if let Err(error) = state.inner.db.batch_reorder_sessions(&orders) {
            tracing::warn!(
                "Remote session reorder mirror refresh failed on {}: {}",
                host_alias,
                error
            );
        }
        best_effort_sync_remote_host(&state, &host_alias, port, "session reorder");
        return StatusCode::OK;
    }

    let orders = items
        .iter()
        .map(|item| (item.id.clone(), item.sort_order, item.group_id.clone()))
        .collect::<Vec<_>>();
    if state.inner.db.batch_reorder_sessions(&orders).is_err() {
        return StatusCode::INTERNAL_SERVER_ERROR;
    }

    for item in &items {
        let Some(ref group_id) = item.group_id else {
            continue;
        };
        if let Ok(uuid) = Uuid::parse_str(&item.id) {
            if let Ok(new_gid) = Uuid::parse_str(group_id) {
                if let Some(session) = state.inner.sessions.get(&uuid) {
                    session.set_group_id(new_gid);
                }
            }
        }
    }

    StatusCode::OK
}

pub async fn get_scrollback(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<ScrollbackQuery>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if let Ok(Some(ssh_host)) = state.inner.db.get_session_ssh_host(&id) {
        let port = ready_tunnel_port(&state, &ssh_host)?;
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

    let uuid = Uuid::parse_str(&id).map_err(|_| StatusCode::BAD_REQUEST)?;

    if let Some(session) = state.get_session(uuid) {
        let data = session
            .scrollback
            .lock()
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
            .read_disk(query.offset, query.limit)
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let b64 = base64::engine::general_purpose::STANDARD;
        return Ok(Json(serde_json::json!({
            "data": b64.encode(&data),
            "offset": query.offset,
            "length": data.len(),
        })));
    }

    state
        .inner
        .db
        .list_sessions()
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .into_iter()
        .find(|session| session.id == id)
        .ok_or(StatusCode::NOT_FOUND)?;

    let session_dir = format!("{}/sessions/{}", state.inner.config.data_dir(), uuid);
    let scrollback_path = format!("{}/scrollback.raw", session_dir);
    if !std::path::Path::new(&scrollback_path).exists() {
        let b64 = base64::engine::general_purpose::STANDARD;
        return Ok(Json(serde_json::json!({
            "data": b64.encode(b""),
            "offset": query.offset,
            "length": 0,
        })));
    }
    let scrollback = crate::persistence::scrollback::ScrollbackBuffer::new(
        &session_dir,
        0,
        state.inner.config.terminal.scrollback_disk_max_mb,
    );
    let data = scrollback
        .read_disk(query.offset, query.limit)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    let b64 = base64::engine::general_purpose::STANDARD;
    Ok(Json(serde_json::json!({
        "data": b64.encode(&data),
        "offset": query.offset,
        "length": data.len(),
    })))
}

async fn create_remote_session(
    state: &AppState,
    group: &GroupRow,
    req: CreateSessionRequest,
    ssh_host: &str,
) -> Result<(StatusCode, Json<SessionRow>), StatusCode> {
    let port = ready_tunnel_port(state, ssh_host)?;
    let id = req.id.unwrap_or_else(Uuid::new_v4);
    let remote_command = forwarded_remote_command(req.command.as_deref(), ssh_host);

    if tokio::net::TcpStream::connect(("127.0.0.1", port))
        .await
        .is_err()
    {
        state.inner.remote_manager.clear_dead_tunnel(ssh_host);
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }

    let response = reqwest::Client::new()
        .post(format!("http://127.0.0.1:{port}/api/sessions"))
        .json(&RemoteCreateRequest {
            group_id: group.id.clone(),
            name: req.name.clone(),
            command: remote_command,
            cwd: req.cwd.clone(),
            id: Some(id),
            local_group_id: None,
        })
        .send()
        .await
        .map_err(|e| {
            tracing::error!("Remote session POST failed: {}", e);
            StatusCode::BAD_GATEWAY
        })?;

    if !response.status().is_success() {
        let remote_status = response.status();
        let body_text = response.text().await.unwrap_or_default();
        tracing::error!("Remote server returned {}: {}", remote_status, body_text);
        return Err(StatusCode::BAD_GATEWAY);
    }

    let remote_row: SessionRow = response.json().await.map_err(|e| {
        tracing::error!("Failed to parse remote session response: {}", e);
        StatusCode::BAD_GATEWAY
    })?;
    state
        .inner
        .db
        .upsert_remote_session_mirror(&remote_row)
        .map_err(|e| {
            tracing::error!("Failed to store remote session mirror: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        })?;
    best_effort_sync_remote_host(state, ssh_host, port, "session create");

    Ok((StatusCode::CREATED, Json(remote_row)))
}

fn forwarded_remote_command(command: Option<&str>, ssh_host: &str) -> Option<String> {
    let command = command?;
    let trimmed = command.trim();
    if trimmed.is_empty() {
        return None;
    }

    let legacy_wrapper = format!("ssh {ssh_host}");
    if trimmed == legacy_wrapper {
        return None;
    }

    Some(command.to_string())
}

fn validate_requested_group(
    state: &AppState,
    current_host: Option<&str>,
    requested_group_id: Option<&str>,
) -> Result<Option<String>, StatusCode> {
    let Some(group_id) = requested_group_id else {
        return Ok(current_host.map(str::to_string));
    };
    let target_group = state
        .inner
        .db
        .get_group(group_id)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .ok_or(StatusCode::BAD_REQUEST)?;
    let target_host = target_group.ssh_host.clone();
    match (current_host, target_host.as_deref()) {
        (Some(current), Some(target)) if current == target => Ok(target_host),
        (None, None) => Ok(None),
        _ => Err(StatusCode::BAD_REQUEST),
    }
}

fn ready_tunnel_port(state: &AppState, host_alias: &str) -> Result<u16, StatusCode> {
    match state.inner.remote_manager.get_tunnel_port(host_alias) {
        Some(port) => Ok(port),
        None => {
            state
                .inner
                .remote_manager
                .trigger_connect_if_needed(host_alias);
            Err(StatusCode::SERVICE_UNAVAILABLE)
        }
    }
}

async fn sync_remote_host(state: &AppState, host_alias: &str, port: u16) -> Result<(), StatusCode> {
    crate::remote::sync::sync_remote_host(
        &state.inner.db,
        host_alias,
        port,
        &state.inner.ssh_fg,
        &state.inner.ssh_live_sessions,
        Some(state),
    )
    .await
    .map_err(|_| StatusCode::BAD_GATEWAY)
}

fn best_effort_sync_remote_host(state: &AppState, host_alias: &str, port: u16, operation: &str) {
    let state = state.clone();
    let host_alias = host_alias.to_string();
    let operation = operation.to_string();
    tokio::spawn(async move {
        if let Err(error) = sync_remote_host(&state, &host_alias, port).await {
            tracing::warn!(
                "Remote {} sync failed for {}: {:?}",
                operation,
                host_alias,
                error
            );
        }
    });
}

#[cfg(test)]
mod tests {
    use super::forwarded_remote_command;

    #[test]
    fn forwarded_remote_command_drops_legacy_transport_wrapper_only() {
        assert_eq!(forwarded_remote_command(Some("ssh devbox"), "devbox"), None);
        assert_eq!(
            forwarded_remote_command(Some("ssh otherbox"), "devbox"),
            Some("ssh otherbox".to_string())
        );
        assert_eq!(
            forwarded_remote_command(Some("htop"), "devbox"),
            Some("htop".to_string())
        );
    }
}
