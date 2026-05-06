use axum::http::StatusCode;
use axum::Json;
use serde::Serialize;

use crate::ssh_config;

#[derive(Serialize)]
pub struct SshHostWithStatus {
    pub host: String,
    pub hostname: Option<String>,
    pub user: Option<String>,
    pub port: Option<u16>,
    pub identity_file: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reachable: Option<bool>,
}

pub async fn list_ssh_hosts() -> Result<Json<Vec<SshHostWithStatus>>, StatusCode> {
    let hosts = ssh_config::parse_ssh_config("~/.ssh/config");
    let results = hosts
        .into_iter()
        .map(|host| SshHostWithStatus {
            host: host.host,
            hostname: host.hostname,
            user: host.user,
            port: host.port,
            identity_file: host.identity_file,
            reachable: None,
        })
        .collect();

    Ok(Json(results))
}
