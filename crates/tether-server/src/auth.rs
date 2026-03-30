use axum::extract::{Request, State};
use axum::http::StatusCode;
use axum::middleware::Next;
use axum::response::Response;

use crate::state::AppState;

pub async fn auth_middleware(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Result<Response, StatusCode> {
    if let Some(ref expected_token) = state.inner.config.server.auth_token {
        let auth_header = request
            .headers()
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");

        let token = auth_header.strip_prefix("Bearer ").unwrap_or("");
        if token != expected_token {
            return Err(StatusCode::UNAUTHORIZED);
        }
    }

    Ok(next.run(request).await)
}
