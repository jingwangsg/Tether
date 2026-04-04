use std::time::Duration;

use super::client::SshClient;

/// Workspace root embedded at compile time (two levels up from this crate's manifest).
const WORKSPACE_ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");
const CRATE_ROOT: &str = env!("CARGO_MANIFEST_DIR");

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn remote_start_command() -> String {
    let mut prefix = String::new();
    if let Ok(rust_log) = std::env::var("RUST_LOG") {
        if !rust_log.trim().is_empty() {
            prefix.push_str("RUST_LOG=");
            prefix.push_str(&shell_quote(rust_log.trim()));
            prefix.push(' ');
        }
    }
    format!("{prefix}~/.tether/bin/tether-server --daemon --no-ssh-scan")
}

fn fingerprint_paths() -> [std::path::PathBuf; 5] {
    let workspace = std::path::Path::new(WORKSPACE_ROOT);
    let crate_root = std::path::Path::new(CRATE_ROOT);
    [
        workspace.join("Cargo.toml"),
        workspace.join("Cargo.lock"),
        crate_root.join("Cargo.toml"),
        crate_root.join("src"),
        crate_root.join("assets"),
    ]
}

fn collect_fingerprint_files(
    path: &std::path::Path,
    files: &mut Vec<std::path::PathBuf>,
) -> anyhow::Result<()> {
    if !path.exists() {
        return Ok(());
    }
    if path.is_file() {
        files.push(path.to_path_buf());
        return Ok(());
    }
    if path.is_dir() {
        let mut entries = std::fs::read_dir(path)?.collect::<Result<Vec<_>, _>>()?;
        entries.sort_by_key(|entry| entry.path());
        for entry in entries {
            collect_fingerprint_files(&entry.path(), files)?;
        }
    }
    Ok(())
}

fn fnv1a_update(hash: &mut u64, bytes: &[u8]) {
    const FNV_OFFSET_BASIS: u64 = 0xcbf29ce484222325;
    const FNV_PRIME: u64 = 0x100000001b3;

    if *hash == 0 {
        *hash = FNV_OFFSET_BASIS;
    }
    for byte in bytes {
        *hash ^= u64::from(*byte);
        *hash = hash.wrapping_mul(FNV_PRIME);
    }
}

fn current_source_fingerprint() -> anyhow::Result<String> {
    let workspace = std::path::Path::new(WORKSPACE_ROOT);
    let mut files = Vec::new();
    for path in fingerprint_paths() {
        collect_fingerprint_files(&path, &mut files)?;
    }
    files.sort();

    let mut hash = 0u64;
    for file in files {
        let rel = file.strip_prefix(workspace).unwrap_or(&file);
        fnv1a_update(&mut hash, rel.to_string_lossy().as_bytes());
        fnv1a_update(&mut hash, &[0]);
        fnv1a_update(&mut hash, &std::fs::read(&file)?);
        fnv1a_update(&mut hash, &[0xff]);
    }

    Ok(format!("{hash:016x}"))
}

fn current_cache_stamp() -> anyhow::Result<String> {
    Ok(format!(
        "{}:{}",
        env!("CARGO_PKG_VERSION"),
        current_source_fingerprint()?
    ))
}

/// Ensure `~/.tether/bin/tether-server` on the remote is present, up-to-date,
/// and running as a daemon.
pub async fn ensure_deployed(client: &SshClient) -> anyhow::Result<()> {
    ensure_available(client, true).await
}

/// Ensure the remote daemon is available without tearing down an already-running
/// daemon. Safe for normal startup: it may upload/start, but never kills.
pub async fn ensure_started_without_restart(client: &SshClient) -> anyhow::Result<()> {
    ensure_available(client, false).await
}

async fn ensure_available(client: &SshClient, allow_replace_running: bool) -> anyhow::Result<()> {
    // 1. Detect remote OS + arch
    let (_, uname, _) = client.exec("uname -sm").await?;
    let uname = uname.trim();
    let target = uname_to_target(uname)
        .ok_or_else(|| anyhow::anyhow!("Unsupported remote platform: {}", uname))?;

    // 2. Compare versions
    let (_, remote_ver, _) = client
        .exec("~/.tether/bin/tether-server --version 2>/dev/null || echo NOTFOUND")
        .await?;
    let remote_ver = remote_ver.trim();
    let local_ver = env!("CARGO_PKG_VERSION");
    // clap --version output is "tether-server X.Y.Z"
    let remote_needs_update = remote_ver == "NOTFOUND" || !remote_ver.contains(local_ver);

    if remote_needs_update {
        tracing::info!(
            "Deploying tether-server {} to {} (remote has: {})",
            local_ver,
            client.host_alias,
            remote_ver
        );
        let binary = get_or_build_linux_binary(target)?;
        client.exec("mkdir -p ~/.tether/bin").await?;
        client
            .upload(&binary, "~/.tether/bin/tether-server")
            .await?;
        client.exec("chmod +x ~/.tether/bin/tether-server").await?;
        tracing::info!("Binary uploaded to {}", client.host_alias);

        if allow_replace_running {
            // Kill running daemon (if any), wait for it to exit, then remove the
            // PID file so the liveness check below always starts a fresh daemon.
            client
                .exec(
                    "pid=$(cat ~/.tether/tether.pid 2>/dev/null); \
                     if [ -n \"$pid\" ]; then \
                         kill \"$pid\" 2>/dev/null; \
                         for i in 1 2; do kill -0 \"$pid\" 2>/dev/null || break; sleep 1; done; \
                     fi; \
                     rm -f ~/.tether/tether.pid; \
                     true",
                )
                .await
                .ok();
        }
    } else {
        tracing::debug!(
            "tether-server {} already up-to-date on {}",
            local_ver,
            client.host_alias
        );
    }

    // 3. Check if daemon is already running
    let (_, alive_out, _) = client
        .exec(
            "pid=$(cat ~/.tether/tether.pid 2>/dev/null); \
             [ -n \"$pid\" ] && kill -0 \"$pid\" 2>/dev/null && echo alive || echo dead",
        )
        .await?;

    if alive_out.trim() != "alive" {
        tracing::info!("Starting tether-server daemon on {}", client.host_alias);
        // --no-ssh-scan: remote daemon only manages PTY sessions, never re-deploys
        client.exec(&remote_start_command()).await?;
    } else {
        tracing::debug!(
            "tether-server daemon already running on {}",
            client.host_alias
        );
    }

    // 4. Poll until the remote server responds on port 7680
    wait_for_ready(client).await
}

/// Return the remote `tether-server` version string if the binary exists.
pub async fn remote_binary_version(client: &SshClient) -> anyhow::Result<Option<String>> {
    let (_, remote_ver, _) = client
        .exec("~/.tether/bin/tether-server --version 2>/dev/null || echo NOTFOUND")
        .await?;
    let remote_ver = remote_ver.trim();
    if remote_ver == "NOTFOUND" {
        return Ok(None);
    }
    Ok(Some(remote_ver.to_string()))
}

/// Kill any running tether-server processes and delete `~/.tether` on the remote host.
/// Called when `--restart-remote` is set; a clean re-deploy follows via the normal scanner.
pub async fn restart_remote(client: &SshClient) -> anyhow::Result<()> {
    tracing::info!("Restarting remote tether-server on {}", client.host_alias);

    // Kill all tether-server processes ([t] trick avoids matching grep itself).
    // "; true" ensures the pipeline always exits 0 even when no processes match.
    let (kill_code, _, kill_err) = client
        .exec("ps aux | grep '[t]ether-server' | awk '{print $2}' | xargs -r kill -9 2>/dev/null; true")
        .await?;
    if kill_code != 0 {
        tracing::warn!(
            "kill command on {} exited {}: {}",
            client.host_alias,
            kill_code,
            kill_err.trim()
        );
    }

    // Wipe the entire ~/.tether directory so ensure_deployed starts fresh.
    let (rm_code, _, rm_err) = client.exec("rm -rf ~/.tether").await?;
    if rm_code != 0 {
        tracing::warn!(
            "rm -rf ~/.tether on {} exited {}: {}",
            client.host_alias,
            rm_code,
            rm_err.trim()
        );
    }

    tracing::info!("Remote cleanup done for {}", client.host_alias);
    Ok(())
}

/// Map `uname -sm` output to a Rust target triple.
pub(crate) fn uname_to_target(uname: &str) -> Option<&'static str> {
    match uname {
        s if s.contains("Linux") && s.contains("x86_64") => Some("x86_64-unknown-linux-musl"),
        s if s.contains("Linux") && s.contains("aarch64") => Some("aarch64-unknown-linux-musl"),
        s if s.contains("Linux") && s.contains("arm") => Some("armv7-unknown-linux-musleabihf"),
        _ => None,
    }
}

/// Return the binary bytes for the given Rust target triple, building via
/// `cargo zigbuild` if the cache is stale or missing.
fn get_or_build_linux_binary(target: &str) -> anyhow::Result<Vec<u8>> {
    let cache_dir = shellexpand::tilde("~/.tether/cache").to_string();
    std::fs::create_dir_all(&cache_dir)?;

    let cache_path = format!("{}/tether-server-{}", cache_dir, target);
    let cache_stamp_path = format!("{}.version", cache_path);
    let expected_stamp = current_cache_stamp()?;

    // Cache hit: binary exists and source fingerprint matches
    if std::path::Path::new(&cache_path).exists() {
        if let Ok(cached_stamp) = std::fs::read_to_string(&cache_stamp_path) {
            if cached_stamp.trim() == expected_stamp {
                tracing::debug!("Using cached binary for {}", target);
                return Ok(std::fs::read(&cache_path)?);
            }
        }
    }

    // Verify workspace root exists (only works when running from source)
    let workspace = std::path::Path::new(WORKSPACE_ROOT);
    if !workspace.join("Cargo.toml").exists() {
        anyhow::bail!(
            "Auto-deploy requires running tether-server from source. \
             Install tether-server manually on the remote, or run from the source tree."
        );
    }

    // Cross-compile via cargo zigbuild
    tracing::info!("Cross-compiling tether-server for {} ...", target);
    let status = std::process::Command::new("cargo")
        .args([
            "zigbuild",
            "--target",
            target,
            "--release",
            "-p",
            "tether-server",
        ])
        .current_dir(workspace)
        .status()
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                anyhow::anyhow!(
                    "cargo-zigbuild not found. Install it with:\n  \
                     cargo install cargo-zigbuild && brew install zig"
                )
            } else {
                anyhow::anyhow!("Failed to run cargo zigbuild: {}", e)
            }
        })?;

    if !status.success() {
        anyhow::bail!("cargo zigbuild failed for target {}", target);
    }

    let built = workspace
        .join("target")
        .join(target)
        .join("release")
        .join("tether-server");

    std::fs::copy(&built, &cache_path)?;
    std::fs::write(&cache_stamp_path, expected_stamp)?;

    tracing::info!("Built and cached binary for {}", target);
    Ok(std::fs::read(&cache_path)?)
}

/// Poll until the remote tether-server is listening on port 7680, or time out.
/// Uses a POSIX/shell-agnostic probe: Python3 TCP connect (available on all
/// modern Linux targets) with a PID-file liveness fallback.
async fn wait_for_ready(client: &SshClient) -> anyhow::Result<()> {
    // python3 TCP probe works regardless of the remote user's login shell.
    // Falls back to a POSIX kill-0 PID check in the unlikely case python3 is absent.
    let check = concat!(
        "python3 -c 'import socket; s=socket.socket(); s.settimeout(1); ",
        "r=s.connect_ex((\"localhost\",7680)); s.close(); print(\"ok\" if r==0 else \"fail\")' ",
        "2>/dev/null || ",
        "{ pid=$(cat ~/.tether/tether.pid 2>/dev/null); ",
        "[ -n \"$pid\" ] && kill -0 \"$pid\" 2>/dev/null && echo ok || echo fail; }"
    );
    for attempt in 1..=20 {
        tokio::time::sleep(Duration::from_millis(500)).await;
        if let Ok((_, out, _)) = client.exec(check).await {
            if out.trim() == "ok" {
                tracing::info!("Remote tether-server on {} is ready", client.host_alias);
                return Ok(());
            }
        }
        tracing::debug!("Waiting for remote tether-server ({}/20)...", attempt);
    }
    anyhow::bail!(
        "Remote tether-server on {} did not become ready in time",
        client.host_alias
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uname_linux_x86_64() {
        assert_eq!(
            uname_to_target("Linux x86_64"),
            Some("x86_64-unknown-linux-musl")
        );
    }

    #[test]
    fn uname_linux_aarch64() {
        assert_eq!(
            uname_to_target("Linux aarch64"),
            Some("aarch64-unknown-linux-musl")
        );
    }

    #[test]
    fn uname_linux_arm() {
        assert_eq!(
            uname_to_target("Linux armv7l"),
            Some("armv7-unknown-linux-musleabihf")
        );
    }

    #[test]
    fn uname_darwin_unsupported() {
        // macOS → macOS copies the local binary directly (A1), no cross-compile needed
        assert_eq!(uname_to_target("Darwin arm64"), None);
    }

    #[test]
    fn uname_unknown_platform() {
        assert_eq!(uname_to_target("FreeBSD amd64"), None);
    }

    #[test]
    fn uname_with_trailing_newline_still_matches() {
        // The function uses substring matching so trailing whitespace does not prevent a match.
        // The caller in ensure_deployed trims the output with .trim() before calling this.
        assert_eq!(
            uname_to_target("Linux x86_64\n"),
            Some("x86_64-unknown-linux-musl")
        );
    }
}
