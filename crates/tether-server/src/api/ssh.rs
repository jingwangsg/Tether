use std::time::Duration;

use axum::http::StatusCode;
use axum::Json;
use serde::Serialize;
use tokio::net::TcpStream;
use tokio::time::timeout;

use crate::ssh_config;

#[derive(Serialize)]
pub struct SshHostWithStatus {
    pub host: String,
    pub hostname: Option<String>,
    pub user: Option<String>,
    pub port: Option<u16>,
    pub identity_file: Option<String>,
    pub reachable: bool,
}

pub async fn list_ssh_hosts() -> Result<Json<Vec<SshHostWithStatus>>, StatusCode> {
    let hosts = ssh_config::parse_ssh_config("~/.ssh/config");

    let mut handles = Vec::new();
    for host in hosts {
        handles.push(tokio::spawn(async move {
            let target = host.hostname.as_deref().unwrap_or(&host.host);
            let port = host.port.unwrap_or(22);
            let addr = format!("{}:{}", target, port);
            let reachable = timeout(Duration::from_secs(2), TcpStream::connect(&addr))
                .await
                .map(|r| r.is_ok())
                .unwrap_or(false);

            SshHostWithStatus {
                host: host.host,
                hostname: host.hostname,
                user: host.user,
                port: host.port,
                identity_file: host.identity_file,
                reachable,
            }
        }));
    }

    let mut results = Vec::new();
    for handle in handles {
        if let Ok(status) = handle.await {
            results.push(status);
        }
    }

    Ok(Json(results))
}
