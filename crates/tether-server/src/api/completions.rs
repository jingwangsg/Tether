use axum::extract::Query;
use axum::Json;
use serde::Deserialize;
use std::time::Duration;

#[derive(Deserialize)]
pub struct CompletionQuery {
    pub path: String,
}

pub async fn complete_path(Query(query): Query<CompletionQuery>) -> Json<Vec<String>> {
    // Normalize bare ~ to ~/ so we list home directory contents
    let path = if query.path == "~" { "~/".to_string() } else { query.path.clone() };
    let expanded = shellexpand::tilde(&path).to_string();

    // Restrict completions to the user's home directory (canonicalize both sides)
    let home_raw = shellexpand::tilde("~").to_string();
    let home = std::path::Path::new(&home_raw)
        .canonicalize()
        .unwrap_or_else(|_| std::path::PathBuf::from(&home_raw));
    let resolved = std::path::Path::new(&expanded);
    if let Ok(canonical_parent) = resolved.canonicalize().or_else(|_| {
        // If path doesn't exist yet, canonicalize its parent
        resolved.parent().map(|p| p.canonicalize()).unwrap_or_else(|| Ok(resolved.to_path_buf()))
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
        .filter(|e| {
            e.file_type().map(|ft| ft.is_dir()).unwrap_or(false)
        })
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

/// Returns true if the path contains characters that could enable shell injection.
fn has_dangerous_chars(s: &str) -> bool {
    s.chars().any(|c| matches!(c, ';' | '`' | '$' | '|' | '&' | '(' | ')' | '{' | '}' | '<' | '>' | '\'' | '"' | '\\' | '\n' | '\r'))
}

pub async fn complete_remote_path(Query(query): Query<RemoteCompletionQuery>) -> Json<Vec<String>> {
    if has_dangerous_chars(&query.path) || has_dangerous_chars(&query.host) {
        return Json(vec![]);
    }

    // Normalize bare ~ to ~/ so the glob expands correctly
    let path = if query.path == "~" { "~/".to_string() } else { query.path.clone() };
    let ls_arg = format!("{}*", path);

    let child = tokio::process::Command::new("ssh")
        .arg("-o").arg("ConnectTimeout=3")
        .arg("-o").arg("BatchMode=yes")
        .arg(&query.host)
        .arg(format!("ls -1dp {} 2>/dev/null", ls_arg))
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn();

    let child = match child {
        Ok(c) => c,
        Err(_) => return Json(vec![]),
    };

    let result = tokio::time::timeout(Duration::from_secs(5), child.wait_with_output()).await;
    let output = match result {
        Ok(Ok(out)) => out,
        _ => return Json(vec![]),
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut results: Vec<String> = stdout
        .lines()
        .filter(|line| !line.is_empty() && line.ends_with('/'))
        .map(|s| s.to_string())
        .collect();

    results.sort();
    results.truncate(20);
    Json(results)
}

#[cfg(test)]
mod tests {
    use super::*;
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
}
