use axum::extract::State;
use axum::Json;

use crate::remote::manager::RemoteHostStatus;
use crate::state::AppState;

pub async fn list_remote_hosts(State(state): State<AppState>) -> Json<Vec<RemoteHostStatus>> {
    Json(state.inner.remote_manager.list_statuses())
}
