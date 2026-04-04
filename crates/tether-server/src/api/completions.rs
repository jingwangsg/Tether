use axum::extract::Query;
use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;
use std::time::Duration;

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

#[derive(Debug, PartialEq, Eq)]
enum RemoteCompletionError {
    Spawn(String),
    Timeout,
    Ssh(String),
}

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

fn remote_completion_error_response(error: RemoteCompletionError) -> (StatusCode, String) {
    match error {
        RemoteCompletionError::Spawn(message) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("failed to start ssh: {}", message),
        ),
        RemoteCompletionError::Timeout => (
            StatusCode::GATEWAY_TIMEOUT,
            "ssh completion timed out".to_string(),
        ),
        RemoteCompletionError::Ssh(message) => (StatusCode::SERVICE_UNAVAILABLE, message),
    }
}

fn summarize_ssh_stderr(stderr: &[u8]) -> Option<String> {
    let stderr = String::from_utf8_lossy(stderr);
    stderr
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(ToOwned::to_owned)
}

async fn complete_remote_path_inner(
    query: &RemoteCompletionQuery,
    ssh_bin: &str,
    timeout_duration: Duration,
) -> Result<Vec<String>, RemoteCompletionError> {
    if has_dangerous_chars(&query.path) || has_dangerous_chars(&query.host) {
        return Ok(vec![]);
    }

    // Normalize bare ~ to ~/ so the glob expands correctly
    let path = if query.path == "~" {
        "~/".to_string()
    } else {
        query.path.clone()
    };
    let ls_arg = format!("{}*", path);

    let child = tokio::process::Command::new(ssh_bin)
        .arg("-o")
        .arg("ConnectTimeout=3")
        .arg("-o")
        .arg("BatchMode=yes")
        .arg(&query.host)
        .arg(format!("ls -1dp {} 2>/dev/null", ls_arg))
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn();

    let child = child.map_err(|error| RemoteCompletionError::Spawn(error.to_string()))?;

    let result = tokio::time::timeout(timeout_duration, child.wait_with_output()).await;
    let output = match result {
        Ok(Ok(output)) => output,
        Ok(Err(error)) => return Err(RemoteCompletionError::Spawn(error.to_string())),
        Err(_) => return Err(RemoteCompletionError::Timeout),
    };

    if !output.status.success() {
        if let Some(stderr) = summarize_ssh_stderr(&output.stderr) {
            return Err(RemoteCompletionError::Ssh(stderr));
        }
        return Ok(vec![]);
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut results: Vec<String> = stdout
        .lines()
        .filter(|line| !line.is_empty() && line.ends_with('/'))
        .map(|s| s.to_string())
        .collect();

    results.sort();
    results.truncate(20);
    Ok(results)
}

async fn complete_remote_path_with_ssh_bin(
    query: &RemoteCompletionQuery,
    ssh_bin: &str,
    timeout_duration: Duration,
) -> Result<Json<Vec<String>>, (StatusCode, String)> {
    complete_remote_path_inner(query, ssh_bin, timeout_duration)
        .await
        .map(Json)
        .map_err(remote_completion_error_response)
}

pub async fn complete_remote_path(
    Query(query): Query<RemoteCompletionQuery>,
) -> Result<Json<Vec<String>>, (StatusCode, String)> {
    complete_remote_path_with_ssh_bin(&query, "ssh", Duration::from_secs(5)).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::extract::Query;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

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
        // /etc is outside $HOME
        let results = complete("/etc/").await;
        assert!(results.is_empty(), "should reject paths outside $HOME");
    }

    #[tokio::test]
    async fn completion_skips_hidden_directories() {
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

    fn write_fake_ssh_script(body: &str) -> (tempfile::TempDir, String) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("fake_ssh.sh");
        fs::write(&path, format!("#!/bin/sh\n{}", body)).unwrap();

        let mut permissions = fs::metadata(&path).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&path, permissions).unwrap();

        (dir, path.to_string_lossy().into_owned())
    }

    async fn complete_remote_with_bin(
        ssh_bin: &str,
        host: &str,
        path: &str,
        timeout_duration: Duration,
    ) -> Result<Vec<String>, (StatusCode, String)> {
        let query = RemoteCompletionQuery {
            host: host.to_string(),
            path: path.to_string(),
        };

        complete_remote_path_with_ssh_bin(&query, ssh_bin, timeout_duration)
            .await
            .map(|Json(results)| results)
    }

    #[tokio::test]
    async fn remote_completion_nonzero_exit_without_stderr_returns_empty_results() {
        let (_dir, ssh_bin) = write_fake_ssh_script("exit 2\n");

        let results =
            complete_remote_with_bin(&ssh_bin, "fake-host", "~/missing", Duration::from_secs(1))
                .await
                .unwrap();

        assert!(results.is_empty());
    }

    #[tokio::test]
    async fn remote_completion_ssh_failure_returns_non_2xx_error() {
        let (_dir, ssh_bin) =
            write_fake_ssh_script("echo 'Permission denied (publickey).' >&2\nexit 255\n");

        let error = complete_remote_with_bin(&ssh_bin, "fake-host", "~/", Duration::from_secs(5))
            .await
            .unwrap_err();

        assert_eq!(error.0, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(error.1, "Permission denied (publickey).");
    }

    #[tokio::test]
    async fn remote_completion_timeout_returns_gateway_timeout() {
        let (_dir, ssh_bin) = write_fake_ssh_script("sleep 1\n");

        let error =
            complete_remote_with_bin(&ssh_bin, "fake-host", "~/", Duration::from_millis(25))
                .await
                .unwrap_err();

        assert_eq!(error.0, StatusCode::GATEWAY_TIMEOUT);
        assert_eq!(error.1, "ssh completion timed out");
    }
}
