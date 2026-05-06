use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;

use crate::remote::manager::{DeployHostError, RemoteHostStatus};
use crate::state::AppState;

pub async fn list_remote_hosts(State(state): State<AppState>) -> Json<Vec<RemoteHostStatus>> {
    Json(state.inner.remote_manager.list_statuses())
}

pub async fn deploy_remote_host(
    State(state): State<AppState>,
    Path(host): Path<String>,
) -> Result<Json<RemoteHostStatus>, StatusCode> {
    state
        .inner
        .remote_manager
        .deploy_host(&host)
        .await
        .map(Json)
        .map_err(remote_host_error_status)
}

pub async fn connect_remote_host(
    State(state): State<AppState>,
    Path(host): Path<String>,
) -> Result<Json<RemoteHostStatus>, StatusCode> {
    state
        .inner
        .remote_manager
        .connect_host(&host)
        .await
        .map(Json)
        .map_err(remote_host_error_status)
}

pub async fn restart_remote_host(
    State(state): State<AppState>,
    Path(host): Path<String>,
) -> Result<Json<RemoteHostStatus>, StatusCode> {
    state
        .inner
        .remote_manager
        .restart_host(&host)
        .await
        .map(Json)
        .map_err(remote_host_error_status)
}

fn remote_host_error_status(error: DeployHostError) -> StatusCode {
    match error {
        DeployHostError::NotConfigured => StatusCode::NOT_FOUND,
        DeployHostError::UpgradeRequired => StatusCode::CONFLICT,
        DeployHostError::Failed(_) => StatusCode::BAD_GATEWAY,
    }
}
