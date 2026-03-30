mod api;
mod auth;
mod config;
mod persistence;
mod pty;
mod server;
mod ssh_config;
mod state;
mod ws;

use clap::Parser;
use tracing_subscriber::EnvFilter;

#[derive(Parser)]
#[command(name = "tether-server", version, about = "Tether — web-based terminal multiplexer")]
struct Cli {
    /// Path to config file
    #[arg(short, long, default_value = "~/.tether/config.toml")]
    config: String,

    /// Override bind address
    #[arg(short, long)]
    bind: Option<String>,

    /// Override port
    #[arg(short, long)]
    port: Option<u16>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let cli = Cli::parse();

    let config_path = shellexpand::tilde(&cli.config).to_string();
    let mut config = config::ServerConfig::load_or_default(&config_path);

    if let Some(bind) = cli.bind {
        config.server.bind = bind;
    }
    if let Some(port) = cli.port {
        config.server.port = port;
    }

    let state = state::AppState::new(config).await?;
    server::run(state).await
}
