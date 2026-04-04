use serde::Serialize;
use std::path::Path;

#[derive(Debug, Clone, Serialize)]
pub struct SshHost {
    pub host: String,
    pub hostname: Option<String>,
    pub user: Option<String>,
    pub port: Option<u16>,
    pub identity_file: Option<String>,
}

/// Parse ~/.ssh/config and return a list of SSH host entries.
/// Skips wildcard patterns (e.g., `Host *`) and `Match` blocks.
/// Follows `Include` directives recursively.
/// Emits one `SshHost` per alias for multi-alias `Host` lines.
pub fn parse_ssh_config(path: &str) -> Vec<SshHost> {
    let expanded = shellexpand::tilde(path);
    let path = Path::new(expanded.as_ref());
    parse_ssh_config_file(path)
}

/// Parse a single SSH config file, recursively following Include directives.
fn parse_ssh_config_file(path: &Path) -> Vec<SshHost> {
    let content = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!("Failed to read SSH config at {}: {}", path.display(), e);
            return Vec::new();
        }
    };
    parse_ssh_config_content_impl(&content, Some(path))
}

/// Internal parser. When `source_path` is provided, Include directives are resolved
/// relative to it (or via tilde expansion + glob). When None, Includes are skipped
/// (used for in-memory test fixtures that have no backing file).
fn parse_ssh_config_content_impl(content: &str, source_path: Option<&Path>) -> Vec<SshHost> {
    let mut hosts = Vec::new();
    // Current stanza: may have multiple aliases, shared settings applied to all at flush.
    let mut cur_aliases: Vec<String> = Vec::new();
    let mut cur_hostname: Option<String> = None;
    let mut cur_user: Option<String> = None;
    let mut cur_port: Option<u16> = None;
    let mut cur_identity_file: Option<String> = None;

    let flush = |aliases: &mut Vec<String>,
                 hostname: &mut Option<String>,
                 user: &mut Option<String>,
                 port: &mut Option<u16>,
                 identity_file: &mut Option<String>,
                 hosts: &mut Vec<SshHost>| {
        for alias in aliases.drain(..) {
            hosts.push(SshHost {
                host: alias,
                hostname: hostname.clone(),
                user: user.clone(),
                port: *port,
                identity_file: identity_file.clone(),
            });
        }
        *hostname = None;
        *user = None;
        *port = None;
        *identity_file = None;
    };

    for line in content.lines() {
        let line = line.trim();

        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        // Skip Match blocks (we don't parse these)
        if line.to_lowercase().starts_with("match ") {
            flush(
                &mut cur_aliases,
                &mut cur_hostname,
                &mut cur_user,
                &mut cur_port,
                &mut cur_identity_file,
                &mut hosts,
            );
            continue;
        }

        // Resolve Include directives recursively (only when a source file is known)
        if line.to_lowercase().starts_with("include ") {
            let pattern = line[8..].trim();
            let expanded = shellexpand::tilde(pattern).to_string();
            if let Some(src) = source_path {
                // If the pattern is relative, resolve it against the directory
                // containing the current config file (mirrors OpenSSH behaviour).
                let abs_pattern = if std::path::Path::new(&expanded).is_relative() {
                    src.parent()
                        .map(|dir| dir.join(&expanded).to_string_lossy().into_owned())
                        .unwrap_or(expanded)
                } else {
                    expanded
                };
                match glob::glob(&abs_pattern) {
                    Ok(paths) => {
                        for entry in paths.flatten() {
                            hosts.extend(parse_ssh_config_file(&entry));
                        }
                    }
                    Err(e) => {
                        tracing::warn!("Skipping malformed Include pattern '{}': {}", pattern, e);
                    }
                }
            } else {
                tracing::debug!("Skipping Include directive (no source path): {}", line);
            }
            continue;
        }

        let (key, value) = match split_config_line(line) {
            Some(kv) => kv,
            None => continue,
        };

        match key.to_lowercase().as_str() {
            "host" => {
                // Flush previous stanza before starting a new one
                flush(
                    &mut cur_aliases,
                    &mut cur_hostname,
                    &mut cur_user,
                    &mut cur_port,
                    &mut cur_identity_file,
                    &mut hosts,
                );

                // Collect all non-wildcard aliases from the Host line
                for alias in value.split_whitespace() {
                    if !alias.contains('*') && !alias.contains('?') {
                        cur_aliases.push(alias.to_string());
                    }
                }
            }
            "hostname" => {
                if !cur_aliases.is_empty() {
                    cur_hostname = Some(value.to_string());
                }
            }
            "user" => {
                if !cur_aliases.is_empty() {
                    cur_user = Some(value.to_string());
                }
            }
            "port" => {
                if !cur_aliases.is_empty() {
                    cur_port = value.parse().ok();
                }
            }
            "identityfile" => {
                if !cur_aliases.is_empty() {
                    cur_identity_file = Some(value.to_string());
                }
            }
            _ => {}
        }
    }

    // Flush the last stanza
    flush(
        &mut cur_aliases,
        &mut cur_hostname,
        &mut cur_user,
        &mut cur_port,
        &mut cur_identity_file,
        &mut hosts,
    );

    hosts
}

#[cfg(test)]
fn parse_ssh_config_content(content: &str) -> Vec<SshHost> {
    parse_ssh_config_content_impl(content, None)
}

fn split_config_line(line: &str) -> Option<(&str, &str)> {
    // SSH config supports both "Key Value" and "Key=Value"
    if let Some(eq_pos) = line.find('=') {
        let key = line[..eq_pos].trim();
        let value = line[eq_pos + 1..].trim();
        if !key.is_empty() && !value.is_empty() {
            return Some((key, value));
        }
    }

    let mut parts = line.splitn(2, char::is_whitespace);
    let key = parts.next()?;
    let value = parts.next()?.trim();
    if value.is_empty() {
        return None;
    }
    Some((key, value))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_standard_config() {
        let config = r#"
Host myserver
    HostName 192.168.1.100
    User jing
    Port 2222
    IdentityFile ~/.ssh/id_rsa

Host devbox
    HostName dev.example.com
    User admin
"#;
        let hosts = parse_ssh_config_content(config);
        assert_eq!(hosts.len(), 2);

        assert_eq!(hosts[0].host, "myserver");
        assert_eq!(hosts[0].hostname.as_deref(), Some("192.168.1.100"));
        assert_eq!(hosts[0].user.as_deref(), Some("jing"));
        assert_eq!(hosts[0].port, Some(2222));
        assert_eq!(hosts[0].identity_file.as_deref(), Some("~/.ssh/id_rsa"));

        assert_eq!(hosts[1].host, "devbox");
        assert_eq!(hosts[1].hostname.as_deref(), Some("dev.example.com"));
        assert_eq!(hosts[1].user.as_deref(), Some("admin"));
        assert_eq!(hosts[1].port, None);
        assert_eq!(hosts[1].identity_file, None);
    }

    #[test]
    fn test_skip_wildcard_hosts() {
        let config = r#"
Host *
    ServerAliveInterval 60

Host myserver
    HostName 10.0.0.1
"#;
        let hosts = parse_ssh_config_content(config);
        assert_eq!(hosts.len(), 1);
        assert_eq!(hosts[0].host, "myserver");
    }

    #[test]
    fn test_skip_match_blocks() {
        let config = r#"
Host myserver
    HostName 10.0.0.1

Match host *.example.com
    User matchuser

Host other
    HostName 10.0.0.2
"#;
        let hosts = parse_ssh_config_content(config);
        assert_eq!(hosts.len(), 2);
        assert_eq!(hosts[0].host, "myserver");
        assert_eq!(hosts[1].host, "other");
    }

    #[test]
    fn test_empty_config() {
        let hosts = parse_ssh_config_content("");
        assert!(hosts.is_empty());
    }

    #[test]
    fn test_comments_only() {
        let config = "# This is a comment\n# Another comment\n";
        let hosts = parse_ssh_config_content(config);
        assert!(hosts.is_empty());
    }

    #[test]
    fn test_equals_syntax() {
        let config = r#"
Host myserver
    HostName=10.0.0.1
    User=jing
    Port=22
"#;
        let hosts = parse_ssh_config_content(config);
        assert_eq!(hosts.len(), 1);
        assert_eq!(hosts[0].hostname.as_deref(), Some("10.0.0.1"));
        assert_eq!(hosts[0].user.as_deref(), Some("jing"));
        assert_eq!(hosts[0].port, Some(22));
    }

    #[test]
    fn test_multi_host_line() {
        let config = "Host server1 server2\n    HostName 10.0.0.1\n";
        let hosts = parse_ssh_config_content(config);
        // Both aliases get their own SshHost entry with shared settings
        assert_eq!(hosts.len(), 2);
        assert_eq!(hosts[0].host, "server1");
        assert_eq!(hosts[0].hostname.as_deref(), Some("10.0.0.1"));
        assert_eq!(hosts[1].host, "server2");
        assert_eq!(hosts[1].hostname.as_deref(), Some("10.0.0.1"));
    }

    #[test]
    fn test_multi_host_line_three_aliases() {
        let config = "Host a b c\n    User jing\n    Port 2222\n";
        let hosts = parse_ssh_config_content(config);
        assert_eq!(hosts.len(), 3);
        for h in &hosts {
            assert_eq!(h.user.as_deref(), Some("jing"));
            assert_eq!(h.port, Some(2222));
        }
        assert_eq!(hosts[0].host, "a");
        assert_eq!(hosts[1].host, "b");
        assert_eq!(hosts[2].host, "c");
    }

    #[test]
    fn test_include_skipped_in_content_mode() {
        // parse_ssh_config_content has no source file, so Include directives are skipped.
        let config = r#"
Include ~/.ssh/config.d/*

Host myserver
    HostName 10.0.0.1
"#;
        let hosts = parse_ssh_config_content(config);
        assert_eq!(hosts.len(), 1);
        assert_eq!(hosts[0].host, "myserver");
    }

    #[test]
    fn test_include_followed_via_parse_ssh_config_file() {
        use std::io::Write;

        // Create a temp directory to hold the main config and an include file
        let dir = tempfile::tempdir().unwrap();
        let config_d = dir.path().join("config.d");
        std::fs::create_dir_all(&config_d).unwrap();

        // Write an included config file
        let included = config_d.join("extra");
        let mut f = std::fs::File::create(&included).unwrap();
        writeln!(f, "Host extra-host").unwrap();
        writeln!(f, "    HostName 10.99.0.1").unwrap();

        // Write the main config with an absolute Include directive
        let include_pattern = format!("{}/*", config_d.display());
        let main_config = dir.path().join("config");
        let mut f = std::fs::File::create(&main_config).unwrap();
        writeln!(f, "Include {}", include_pattern).unwrap();
        writeln!(f, "Host main-host").unwrap();
        writeln!(f, "    HostName 10.0.0.1").unwrap();

        let hosts = parse_ssh_config_file(&main_config);
        // Both the included host and the main host should appear
        assert_eq!(
            hosts.len(),
            2,
            "hosts = {:?}",
            hosts.iter().map(|h| &h.host).collect::<Vec<_>>()
        );
        assert!(hosts.iter().any(|h| h.host == "extra-host"));
        assert!(hosts.iter().any(|h| h.host == "main-host"));
    }

    #[test]
    fn test_include_relative_pattern_resolved_against_config_dir() {
        use std::io::Write;

        // Simulate `Include config.d/*` (relative, no leading slash or tilde)
        let dir = tempfile::tempdir().unwrap();
        let config_d = dir.path().join("config.d");
        std::fs::create_dir_all(&config_d).unwrap();

        let included = config_d.join("host_a");
        let mut f = std::fs::File::create(&included).unwrap();
        writeln!(f, "Host relative-host").unwrap();
        writeln!(f, "    HostName 10.5.0.1").unwrap();

        let main_config = dir.path().join("config");
        let mut f = std::fs::File::create(&main_config).unwrap();
        // Relative include — should be resolved relative to the main config's dir
        writeln!(f, "Include config.d/*").unwrap();
        writeln!(f, "Host base-host").unwrap();
        writeln!(f, "    HostName 10.0.0.1").unwrap();

        let hosts = parse_ssh_config_file(&main_config);
        assert_eq!(
            hosts.len(),
            2,
            "hosts = {:?}",
            hosts.iter().map(|h| &h.host).collect::<Vec<_>>()
        );
        assert!(hosts.iter().any(|h| h.host == "relative-host"));
        assert!(hosts.iter().any(|h| h.host == "base-host"));
    }

    #[test]
    fn test_host_without_details() {
        let config = "Host bare\n";
        let hosts = parse_ssh_config_content(config);
        assert_eq!(hosts.len(), 1);
        assert_eq!(hosts[0].host, "bare");
        assert_eq!(hosts[0].hostname, None);
    }

    #[test]
    fn test_case_insensitive_keys() {
        let config = r#"
host MYSERVER
    hostname 10.0.0.1
    USER jing
    PORT 2222
    IDENTITYFILE ~/.ssh/key
"#;
        let hosts = parse_ssh_config_content(config);
        assert_eq!(hosts.len(), 1);
        assert_eq!(hosts[0].host, "MYSERVER");
        assert_eq!(hosts[0].hostname.as_deref(), Some("10.0.0.1"));
        assert_eq!(hosts[0].user.as_deref(), Some("jing"));
        assert_eq!(hosts[0].port, Some(2222));
        assert_eq!(hosts[0].identity_file.as_deref(), Some("~/.ssh/key"));
    }

    #[test]
    fn test_multi_host_with_wildcard_skips_wildcard_only() {
        // When mixing wildcards and real aliases, only non-wildcard aliases become SshHosts
        let config = "Host server1 * server2\n    HostName 10.0.0.1\n";
        let hosts = parse_ssh_config_content(config);
        assert_eq!(hosts.len(), 2);
        assert_eq!(hosts[0].host, "server1");
        assert_eq!(hosts[1].host, "server2");
    }
}
