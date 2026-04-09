use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;
use std::time::Duration;

use crate::state::AppState;

#[derive(Deserialize)]
pub struct CompletionQuery {
    pub path: String,
}

pub async fn complete_path(Query(query): Query<CompletionQuery>) -> Json<Vec<String>> {
    // Normalize bare ~ to ~/ so we list home directory contents
    let path = if query.path == "~" {
        "~/".to_string()
    } else {
        query.path.clone()
    };
    let expanded = shellexpand::tilde(&path).to_string();

    // Restrict completions to the user's home directory (canonicalize both sides)
    let home_raw = shellexpand::tilde("~").to_string();
    let home = std::path::Path::new(&home_raw)
        .canonicalize()
        .unwrap_or_else(|_| std::path::PathBuf::from(&home_raw));
    let resolved = std::path::Path::new(&expanded);
    if let Ok(canonical_parent) = resolved.canonicalize().or_else(|_| {
        // If path doesn't exist yet, canonicalize its parent
        resolved
            .parent()
            .map(|p| p.canonicalize())
            .unwrap_or_else(|| Ok(resolved.to_path_buf()))
    }) {
        if !canonical_parent.starts_with(&home) {
            return Json(vec![]);
        }
    }

    // Split into parent dir and prefix
    let (parent, prefix) = if expanded.ends_with('/') {
        (expanded.as_str(), "")
    } else {
        match expanded.rfind('/') {
            Some(i) => (&expanded[..=i], &expanded[i + 1..]),
            None => return Json(vec![]),
        }
    };

    let entries = match std::fs::read_dir(parent) {
        Ok(e) => e,
        Err(_) => return Json(vec![]),
    };

    let mut results: Vec<String> = entries
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().map(|ft| ft.is_dir()).unwrap_or(false))
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            if name.starts_with('.') {
                return None; // skip hidden dirs
            }
            if prefix.is_empty() || name.starts_with(prefix) {
                // Reconstruct with tilde if original started with ~
                let full = format!("{}{}/", parent, name);
                if query.path.starts_with('~') {
                    let home = shellexpand::tilde("~").to_string();
                    Some(full.replacen(&home, "~", 1))
                } else {
                    Some(full)
                }
            } else {
                None
            }
        })
        .collect();

    results.sort();
    results.truncate(20);
    Json(results)
}

#[derive(Deserialize)]
pub struct RemoteCompletionQuery {
    pub host: String,
    pub path: String,
}

const REMOTE_HOST_CONNECTING: &str = "remote_host_connecting";
const REMOTE_COMPLETION_PROXY_FAILED: &str = "remote completion proxy failed";
const REMOTE_COMPLETION_PROXY_TIMEOUT: Duration = Duration::from_secs(5);

/// Returns true if the path contains characters that could enable shell injection.
fn has_dangerous_chars(s: &str) -> bool {
    s.chars().any(|c| {
        matches!(
            c,
            ';' | '`'
                | '$'
                | '|'
                | '&'
                | '('
                | ')'
                | '{'
                | '}'
                | '<'
                | '>'
                | '\''
                | '"'
                | '\\'
                | '\n'
                | '\r'
        )
    })
}

fn remote_host_connecting_response() -> (StatusCode, String) {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        REMOTE_HOST_CONNECTING.to_string(),
    )
}

fn reset_remote_completion_tunnel(state: &AppState, host_alias: &str) -> (StatusCode, String) {
    state.inner.remote_manager.clear_dead_tunnel(host_alias);
    state
        .inner
        .remote_manager
        .trigger_connect_if_needed(host_alias);
    remote_host_connecting_response()
}

async fn complete_remote_path_inner(
    state: &AppState,
    query: &RemoteCompletionQuery,
) -> Result<Vec<String>, (StatusCode, String)> {
    if has_dangerous_chars(&query.path) || has_dangerous_chars(&query.host) {
        return Ok(vec![]);
    }

    let port = match state.inner.remote_manager.get_tunnel_port(&query.host) {
        Some(port) => port,
        None => {
            state
                .inner
                .remote_manager
                .trigger_connect_if_needed(&query.host);
            return Err(remote_host_connecting_response());
        }
    };

    if tokio::net::TcpStream::connect(("127.0.0.1", port))
        .await
        .is_err()
    {
        return Err(reset_remote_completion_tunnel(state, &query.host));
    }

    tokio::time::timeout(REMOTE_COMPLETION_PROXY_TIMEOUT, async {
        let response = reqwest::Client::new()
            .get(format!("http://127.0.0.1:{port}/api/completions"))
            .query(&[("path", query.path.as_str())])
            .send()
            .await
            .map_err(|_| reset_remote_completion_tunnel(state, &query.host))?;

        if !response.status().is_success() {
            let body = response.text().await.unwrap_or_default();
            let message = if body.trim().is_empty() {
                REMOTE_COMPLETION_PROXY_FAILED.to_string()
            } else {
                body
            };
            return Err((StatusCode::BAD_GATEWAY, message));
        }

        response.json::<Vec<String>>().await.map_err(|_| {
            (
                StatusCode::BAD_GATEWAY,
                REMOTE_COMPLETION_PROXY_FAILED.to_string(),
            )
        })
    })
    .await
    .map_err(|_| reset_remote_completion_tunnel(state, &query.host))?
}

pub async fn complete_remote_path(
    State(state): State<AppState>,
    Query(query): Query<RemoteCompletionQuery>,
) -> Result<Json<Vec<String>>, (StatusCode, String)> {
    complete_remote_path_inner(&state, &query).await.map(Json)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::ENV_MUTEX;
    use axum::extract::Query;
    use std::fs;

    /// Helper: call complete_path with a given path string.
    async fn complete(path: &str) -> Vec<String> {
        let query = Query(CompletionQuery {
            path: path.to_string(),
        });
        let Json(results) = complete_path(query).await;
        results
    }

    #[tokio::test]
    async fn completion_lists_matching_dirs() {
        let _guard = ENV_MUTEX.lock().unwrap();
        // Create a temp dir inside $HOME so it passes the security check
        let home = shellexpand::tilde("~").to_string();
        let base = tempfile::tempdir_in(&home).unwrap();
        let base_path = base.path();

        fs::create_dir(base_path.join("alpha")).unwrap();
        fs::create_dir(base_path.join("alpha2")).unwrap();
        fs::create_dir(base_path.join("beta")).unwrap();

        // Search for dirs starting with "al"
        let query = format!("{}/al", base_path.display());
        let results = complete(&query).await;
        assert_eq!(results.len(), 2);
        assert!(results.iter().all(|r| r.contains("alpha")));
    }

    #[tokio::test]
    async fn completion_empty_prefix_lists_all_non_hidden() {
        let _guard = ENV_MUTEX.lock().unwrap();
        let home = shellexpand::tilde("~").to_string();
        let base = tempfile::tempdir_in(&home).unwrap();
        let base_path = base.path();

        fs::create_dir(base_path.join("aaa")).unwrap();
        fs::create_dir(base_path.join("bbb")).unwrap();
        // Also create a regular file — should NOT appear (only dirs)
        fs::write(base_path.join("file.txt"), "").unwrap();

        let query = format!("{}/", base_path.display());
        let results = complete(&query).await;
        assert_eq!(results.len(), 2);
    }

    #[tokio::test]
    async fn completion_rejects_paths_outside_home() {
        let _guard = ENV_MUTEX.lock().unwrap();
        // /etc is outside $HOME
        let results = complete("/etc/").await;
        assert!(results.is_empty(), "should reject paths outside $HOME");
    }

    #[tokio::test]
    async fn completion_skips_hidden_directories() {
        let _guard = ENV_MUTEX.lock().unwrap();
        let home = shellexpand::tilde("~").to_string();
        let base = tempfile::tempdir_in(&home).unwrap();
        let base_path = base.path();

        fs::create_dir(base_path.join(".hidden")).unwrap();
        fs::create_dir(base_path.join("visible")).unwrap();

        let query = format!("{}/", base_path.display());
        let results = complete(&query).await;
        assert_eq!(results.len(), 1);
        assert!(results[0].contains("visible"));
    }

    #[tokio::test]
    async fn completion_truncates_to_20_items() {
        let _guard = ENV_MUTEX.lock().unwrap();
        let home = shellexpand::tilde("~").to_string();
        let base = tempfile::tempdir_in(&home).unwrap();
        let base_path = base.path();

        for i in 0..30 {
            fs::create_dir(base_path.join(format!("dir{:02}", i))).unwrap();
        }

        let query = format!("{}/", base_path.display());
        let results = complete(&query).await;
        assert_eq!(results.len(), 20);
    }
}
