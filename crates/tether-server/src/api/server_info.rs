use axum::extract::State;
use axum::Json;
use serde::Serialize;

use crate::state::AppState;

#[derive(Serialize)]
pub struct ServerInfo {
    pub name: String,
    pub version: String,
    pub sessions_count: usize,
}

pub async fn get_info(State(state): State<AppState>) -> Json<ServerInfo> {
    Json(ServerInfo {
        name: "tether".to_string(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        sessions_count: state.inner.sessions.len(),
    })
}
