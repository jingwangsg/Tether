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
pub fn parse_ssh_config(path: &str) -> Vec<SshHost> {
    let expanded = shellexpand::tilde(path);
    let path = Path::new(expanded.as_ref());
    let content = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!("Failed to read SSH config at {}: {}", path.display(), e);
            return Vec::new();
        }
    };
    parse_ssh_config_content(&content)
}

fn parse_ssh_config_content(content: &str) -> Vec<SshHost> {
    let mut hosts = Vec::new();
    let mut current: Option<SshHost> = None;

    for line in content.lines() {
        let line = line.trim();

        // Skip empty lines and comments
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        // Skip Match blocks (we don't parse these)
        if line.to_lowercase().starts_with("match ") {
            if let Some(host) = current.take() {
                hosts.push(host);
            }
            continue;
        }

        // Skip Include directives
        if line.to_lowercase().starts_with("include ") {
            tracing::debug!("Skipping Include directive: {}", line);
            continue;
        }

        // Parse "Key Value" or "Key=Value"
        let (key, value) = match split_config_line(line) {
            Some(kv) => kv,
            None => continue,
        };

        match key.to_lowercase().as_str() {
            "host" => {
                // Save previous host entry
                if let Some(host) = current.take() {
                    hosts.push(host);
                }

                // Skip wildcard patterns
                if value.contains('*') || value.contains('?') {
                    continue;
                }

                // Handle multiple hosts on one line (take only the first alias)
                let alias = value.split_whitespace().next().unwrap_or(value);
                current = Some(SshHost {
                    host: alias.to_string(),
                    hostname: None,
                    user: None,
                    port: None,
                    identity_file: None,
                });
            }
            "hostname" => {
                if let Some(ref mut h) = current {
                    h.hostname = Some(value.to_string());
                }
            }
            "user" => {
                if let Some(ref mut h) = current {
                    h.user = Some(value.to_string());
                }
            }
            "port" => {
                if let Some(ref mut h) = current {
                    h.port = value.parse().ok();
                }
            }
            "identityfile" => {
                if let Some(ref mut h) = current {
                    h.identity_file = Some(value.to_string());
                }
            }
            _ => {} // Ignore other directives
        }
    }

    // Don't forget the last entry
    if let Some(host) = current {
        hosts.push(host);
    }

    hosts
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
        assert_eq!(hosts.len(), 1);
        // Takes the first alias
        assert_eq!(hosts[0].host, "server1");
    }

    #[test]
    fn test_include_skipped() {
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
}
