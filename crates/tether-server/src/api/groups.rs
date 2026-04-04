use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

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

#[derive(Deserialize, Serialize)]
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
    let target_host = resolve_create_target_host(&state, &req)?;

    if let Some(host_alias) = target_host {
        let port = ready_tunnel_port(&state, &host_alias)?;
        let response = reqwest::Client::new()
            .post(format!("http://127.0.0.1:{port}/api/groups"))
            .json(&serde_json::json!({
                "name": req.name,
                "default_cwd": req.default_cwd,
                "parent_id": req.parent_id,
            }))
            .send()
            .await
            .map_err(|_| StatusCode::BAD_GATEWAY)?;

        if response.status() != StatusCode::CREATED {
            return Err(StatusCode::BAD_GATEWAY);
        }

        let mut remote_group: GroupRow =
            response.json().await.map_err(|_| StatusCode::BAD_GATEWAY)?;
        remote_group.ssh_host = Some(host_alias.clone());
        state
            .inner
            .db
            .upsert_remote_group_mirror(&remote_group, &host_alias)
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        best_effort_sync_remote_host(&state, &host_alias, port, "group create");
        return Ok((StatusCode::CREATED, Json(remote_group)));
    }

    state
        .inner
        .db
        .create_group(&req.name, &req.default_cwd, req.parent_id.as_deref(), None)
        .map(|group| (StatusCode::CREATED, Json(group)))
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}

pub async fn update_group(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(req): Json<UpdateGroupRequest>,
) -> StatusCode {
    let current = match state.inner.db.get_group(&id) {
        Ok(Some(group)) => group,
        Ok(None) => return StatusCode::NOT_FOUND,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR,
    };

    if violates_group_locality(&current, req.ssh_host.as_deref()) {
        return StatusCode::BAD_REQUEST;
    }

    if let Some(host_alias) = current.ssh_host.as_deref() {
        let port = match ready_tunnel_port(&state, host_alias) {
            Ok(port) => port,
            Err(status) => return status,
        };
        let response = match reqwest::Client::new()
            .patch(format!("http://127.0.0.1:{port}/api/groups/{id}"))
            .json(&serde_json::json!({
                "name": req.name,
                "default_cwd": req.default_cwd,
                "sort_order": req.sort_order,
            }))
            .send()
            .await
        {
            Ok(response) => response,
            Err(_) => return StatusCode::BAD_GATEWAY,
        };
        if !response.status().is_success() {
            return StatusCode::BAD_GATEWAY;
        }
        if let Err(error) = state.inner.db.update_group(
            &id,
            req.name.as_deref(),
            req.default_cwd.as_deref(),
            req.sort_order,
            current.ssh_host.as_deref(),
        ) {
            tracing::warn!(
                "Remote group update mirror refresh failed for {} on {}: {}",
                id,
                host_alias,
                error
            );
        }
        best_effort_sync_remote_host(&state, host_alias, port, "group update");
        return StatusCode::OK;
    }

    match state.inner.db.update_group(
        &id,
        req.name.as_deref(),
        req.default_cwd.as_deref(),
        req.sort_order,
        None,
    ) {
        Ok(_) => StatusCode::OK,
        Err(error) if error.to_string().contains("not_found") => StatusCode::NOT_FOUND,
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

pub async fn delete_group(State(state): State<AppState>, Path(id): Path<String>) -> StatusCode {
    let current = match state.inner.db.get_group(&id) {
        Ok(Some(group)) => group,
        Ok(None) => return StatusCode::NOT_FOUND,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR,
    };

    if let Some(host_alias) = current.ssh_host.as_deref() {
        let port = match ready_tunnel_port(&state, host_alias) {
            Ok(port) => port,
            Err(status) => return status,
        };
        let response = match reqwest::Client::new()
            .delete(format!("http://127.0.0.1:{port}/api/groups/{id}"))
            .send()
            .await
        {
            Ok(response) => response,
            Err(_) => return StatusCode::BAD_GATEWAY,
        };
        if !response.status().is_success() {
            return StatusCode::BAD_GATEWAY;
        }
        let group_ids = match state.inner.db.collect_descendant_ids(&id) {
            Ok(ids) => ids,
            Err(error) => {
                tracing::warn!(
                    "Remote group delete mirror lookup failed for {} on {}: {}",
                    id,
                    host_alias,
                    error
                );
                Vec::new()
            }
        };
        if let Ok(sessions) = state.inner.db.get_sessions_in_groups(&group_ids) {
            for session in sessions {
                if let Ok(uuid) = Uuid::parse_str(&session.id) {
                    state.inner.ssh_fg.remove(&uuid);
                }
            }
        }
        if let Err(error) = state.inner.db.delete_group(&id) {
            tracing::warn!(
                "Remote group delete mirror cleanup failed for {} on {}: {}",
                id,
                host_alias,
                error
            );
        }
        best_effort_sync_remote_host(&state, host_alias, port, "group delete");
        return StatusCode::OK;
    }

    let group_ids = match state.inner.db.collect_descendant_ids(&id) {
        Ok(ids) => ids,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR,
    };
    let sessions_to_kill: Vec<_> = state
        .inner
        .sessions
        .iter()
        .filter(|session| group_ids.contains(&session.get_group_id().to_string()))
        .map(|session| session.id)
        .collect();
    for session_id in sessions_to_kill {
        state.kill_session(session_id).ok();
    }

    match state.inner.db.delete_group(&id) {
        Ok(_) => StatusCode::OK,
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

pub async fn batch_reorder_groups(
    State(state): State<AppState>,
    Json(items): Json<Vec<ReorderItem>>,
) -> StatusCode {
    if items.is_empty() {
        return StatusCode::OK;
    }

    let mut host_scope: Option<Option<String>> = None;
    for item in &items {
        let group = match state.inner.db.get_group(&item.id) {
            Ok(Some(group)) => group,
            _ => return StatusCode::BAD_REQUEST,
        };
        match &host_scope {
            Some(scope) if *scope != group.ssh_host => return StatusCode::BAD_REQUEST,
            None => host_scope = Some(group.ssh_host.clone()),
            _ => {}
        }
    }

    if let Some(Some(host_alias)) = host_scope {
        let port = match ready_tunnel_port(&state, &host_alias) {
            Ok(port) => port,
            Err(status) => return status,
        };
        let response = match reqwest::Client::new()
            .post(format!("http://127.0.0.1:{port}/api/groups/reorder"))
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
            .map(|item| (item.id.clone(), item.sort_order))
            .collect::<Vec<_>>();
        if let Err(error) = state.inner.db.batch_reorder_groups(&orders) {
            tracing::warn!(
                "Remote group reorder mirror refresh failed on {}: {}",
                host_alias,
                error
            );
        }
        best_effort_sync_remote_host(&state, &host_alias, port, "group reorder");
        return StatusCode::OK;
    }

    let orders = items
        .into_iter()
        .map(|item| (item.id, item.sort_order))
        .collect::<Vec<_>>();
    match state.inner.db.batch_reorder_groups(&orders) {
        Ok(_) => StatusCode::OK,
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

fn resolve_create_target_host(
    state: &AppState,
    req: &CreateGroupRequest,
) -> Result<Option<String>, StatusCode> {
    if let Some(parent_id) = req.parent_id.as_deref() {
        let parent = state
            .inner
            .db
            .get_group(parent_id)
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
            .ok_or(StatusCode::BAD_REQUEST)?;
        if let Some(parent_host) = parent.ssh_host {
            if let Some(requested_host) = req.ssh_host.as_deref() {
                if requested_host != parent_host {
                    return Err(StatusCode::BAD_REQUEST);
                }
            }
            return Ok(Some(parent_host));
        }
        if req.ssh_host.is_some() {
            return Err(StatusCode::BAD_REQUEST);
        }
    }

    Ok(req.ssh_host.clone())
}

fn violates_group_locality(current: &GroupRow, requested_host: Option<&str>) -> bool {
    match current.ssh_host.as_deref() {
        Some(current_host) => match requested_host {
            Some(host) => host != current_host,
            None => false,
        },
        None => matches!(requested_host, Some(host) if !host.is_empty()),
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
    crate::remote::sync::sync_remote_host(&state.inner.db, host_alias, port, &state.inner.ssh_fg)
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
