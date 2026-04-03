use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerConfig {
    #[serde(default)]
    pub server: ServerSection,
    #[serde(default)]
    pub persistence: PersistenceSection,
    #[serde(default)]
    pub terminal: TerminalSection,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerSection {
    #[serde(default = "default_bind")]
    pub bind: String,
    #[serde(default = "default_port")]
    pub port: u16,
    pub auth_token: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PersistenceSection {
    #[serde(default = "default_data_dir")]
    pub data_dir: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalSection {
    #[serde(default)]
    pub default_shell: String,
    #[serde(default = "default_scrollback_memory_kb")]
    pub scrollback_memory_kb: usize,
    #[serde(default = "default_scrollback_disk_max_mb")]
    pub scrollback_disk_max_mb: usize,
}

fn default_bind() -> String {
    "127.0.0.1".to_string()
}
fn default_port() -> u16 {
    7680
}
fn default_data_dir() -> String {
    "~/.tether".to_string()
}
fn default_scrollback_memory_kb() -> usize {
    100
}
fn default_scrollback_disk_max_mb() -> usize {
    50
}

impl Default for ServerSection {
    fn default() -> Self {
        Self {
            bind: default_bind(),
            port: default_port(),
            auth_token: None,
        }
    }
}

impl Default for PersistenceSection {
    fn default() -> Self {
        Self {
            data_dir: default_data_dir(),
        }
    }
}

impl Default for TerminalSection {
    fn default() -> Self {
        Self {
            default_shell: String::new(),
            scrollback_memory_kb: default_scrollback_memory_kb(),
            scrollback_disk_max_mb: default_scrollback_disk_max_mb(),
        }
    }
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            server: ServerSection::default(),
            persistence: PersistenceSection::default(),
            terminal: TerminalSection::default(),
        }
    }
}

impl ServerConfig {
    pub fn load_or_default(path: &str) -> Self {
        if Path::new(path).exists() {
            match std::fs::read_to_string(path) {
                Ok(content) => match toml::from_str(&content) {
                    Ok(config) => {
                        tracing::info!("Loaded config from {}", path);
                        return config;
                    }
                    Err(e) => tracing::warn!("Failed to parse config {}: {}", path, e),
                },
                Err(e) => tracing::warn!("Failed to read config {}: {}", path, e),
            }
        }
        tracing::info!("Using default config");
        Self::default()
    }

    pub fn data_dir(&self) -> String {
        // Allow override via environment variable (useful for testing)
        if let Ok(dir) = std::env::var("TETHER_DATA_DIR") {
            return dir;
        }
        shellexpand::tilde(&self.persistence.data_dir).to_string()
    }

    pub fn resolve_shell(&self) -> String {
        if !self.terminal.default_shell.is_empty() {
            return self.terminal.default_shell.clone();
        }
        std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::Mutex;

    // Mutex to serialize tests that manipulate environment variables
    static ENV_MUTEX: Mutex<()> = Mutex::new(());

    #[test]
    fn default_values() {
        let config = ServerConfig::default();
        assert_eq!(config.server.bind, "127.0.0.1");
        assert_eq!(config.server.port, 7680);
        assert_eq!(config.persistence.data_dir, "~/.tether");
        assert_eq!(config.terminal.scrollback_memory_kb, 100);
        assert_eq!(config.terminal.scrollback_disk_max_mb, 50);
        assert!(config.terminal.default_shell.is_empty());
        assert!(config.server.auth_token.is_none());
    }

    #[test]
    fn load_or_default_nonexistent_path() {
        let config = ServerConfig::load_or_default("/tmp/tether-test-nonexistent-9f8a7b.toml");
        assert_eq!(config.server.bind, "127.0.0.1");
        assert_eq!(config.server.port, 7680);
    }

    #[test]
    fn load_or_default_valid_toml() {
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        write!(
            tmp,
            r#"
[server]
bind = "127.0.0.1"
port = 9999
auth_token = "tok123"

[persistence]
data_dir = "/data/tether"

[terminal]
default_shell = "/bin/zsh"
scrollback_memory_kb = 200
scrollback_disk_max_mb = 100
"#
        )
        .unwrap();
        tmp.flush().unwrap();

        let config = ServerConfig::load_or_default(tmp.path().to_str().unwrap());
        assert_eq!(config.server.bind, "127.0.0.1");
        assert_eq!(config.server.port, 9999);
        assert_eq!(config.server.auth_token.as_deref(), Some("tok123"));
        assert_eq!(config.persistence.data_dir, "/data/tether");
        assert_eq!(config.terminal.default_shell, "/bin/zsh");
        assert_eq!(config.terminal.scrollback_memory_kb, 200);
        assert_eq!(config.terminal.scrollback_disk_max_mb, 100);
    }

    #[test]
    fn load_or_default_invalid_toml_returns_defaults() {
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        write!(tmp, "this is not valid toml {{{{").unwrap();
        tmp.flush().unwrap();

        let config = ServerConfig::load_or_default(tmp.path().to_str().unwrap());
        // Should gracefully fall back to defaults
        assert_eq!(config.server.bind, "127.0.0.1");
        assert_eq!(config.server.port, 7680);
    }

    #[test]
    fn resolve_shell_with_configured_shell() {
        let mut config = ServerConfig::default();
        config.terminal.default_shell = "/usr/local/bin/fish".to_string();
        assert_eq!(config.resolve_shell(), "/usr/local/bin/fish");
    }

    #[test]
    fn resolve_shell_falls_back_to_env_or_bin_sh() {
        let _guard = ENV_MUTEX.lock().unwrap();
        let config = ServerConfig::default();

        // The default_shell is empty, so it should check $SHELL
        let result = config.resolve_shell();
        if let Ok(shell) = std::env::var("SHELL") {
            assert_eq!(result, shell);
        } else {
            assert_eq!(result, "/bin/sh");
        }
    }

    #[test]
    fn data_dir_with_env_override() {
        let _guard = ENV_MUTEX.lock().unwrap();
        let config = ServerConfig::default();

        // Set the env var with a unique name-value to avoid conflicts
        let test_dir = "/tmp/tether-env-override-test";
        std::env::set_var("TETHER_DATA_DIR", test_dir);
        assert_eq!(config.data_dir(), test_dir);
        std::env::remove_var("TETHER_DATA_DIR");
    }

    #[test]
    fn data_dir_tilde_expansion() {
        let _guard = ENV_MUTEX.lock().unwrap();
        // Make sure TETHER_DATA_DIR is not set
        std::env::remove_var("TETHER_DATA_DIR");

        let config = ServerConfig::default();
        let dir = config.data_dir();
        // The default is "~/.tether", which after expansion should not contain ~
        assert!(!dir.starts_with('~'), "tilde should be expanded: {}", dir);
        assert!(dir.ends_with(".tether"));
    }
}
