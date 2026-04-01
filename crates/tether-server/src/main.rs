mod api;
mod auth;
mod config;
mod persistence;
mod pty;
mod remote;
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

    /// Run as a background daemon (Unix only)
    #[arg(short = 'D', long)]
    daemon: bool,

    /// Disable the SSH host scanner (used when running as a remote daemon deployed
    /// by a local tether-server — the remote instance only manages PTY sessions)
    #[arg(long)]
    no_ssh_scan: bool,

    /// Kill remote tether-server processes and delete ~/.tether on all SSH hosts before starting
    #[arg(long)]
    restart_remote: bool,
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    let config_path = shellexpand::tilde(&cli.config).to_string();
    let mut config = config::ServerConfig::load_or_default(&config_path);

    if let Some(bind) = cli.bind {
        config.server.bind = bind;
    }
    if let Some(port) = cli.port {
        config.server.port = port;
    }

    let data_dir = config.data_dir();

    #[cfg(unix)]
    if cli.daemon {
        daemonize(&data_dir)?;
    }

    // Init tracing after fork so only the daemon child initialises it.
    // In non-daemon mode the behaviour is identical to before.
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let pid_file = format!("{}/tether.pid", data_dir);

    let no_ssh_scan = cli.no_ssh_scan;
    let restart_remote = cli.restart_remote;
    let result = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?
        .block_on(async {
            if restart_remote {
                let hosts = ssh_config::parse_ssh_config("~/.ssh/config");
                if hosts.is_empty() {
                    tracing::warn!("--restart-remote: no hosts found in ~/.ssh/config");
                }
                let mut tasks = Vec::new();
                for host in hosts {
                    tasks.push(tokio::spawn(async move {
                        tracing::info!("--restart-remote: connecting to {}", host.host);
                        match remote::client::SshClient::connect(&host).await {
                            Ok(client) => {
                                if let Err(e) = remote::deploy::restart_remote(&client).await {
                                    tracing::warn!("restart_remote failed for {}: {}", host.host, e);
                                }
                            }
                            Err(e) => {
                                tracing::warn!("Could not connect to {} for restart: {}", host.host, e);
                            }
                        }
                    }));
                }
                for task in tasks {
                    let _ = task.await;
                }
            }

            let state = state::AppState::new(config).await?;
            server::run(state, no_ssh_scan).await
        });

    // Clean up PID file after the server exits (daemon or not)
    #[cfg(unix)]
    if cli.daemon {
        let _ = std::fs::remove_file(&pid_file);
    }

    result
}

/// Check if a process with the PID stored in `pid_file` is alive.
/// Returns the PID if alive, None if dead or file missing.
#[cfg(unix)]
fn check_running(pid_file: &str) -> Option<u32> {
    let content = std::fs::read_to_string(pid_file).ok()?;
    let pid: u32 = content.trim().parse().ok()?;
    // kill(pid, 0) probes liveness without sending a real signal
    let alive = unsafe { libc::kill(pid as libc::pid_t, 0) } == 0;
    if alive { Some(pid) } else { None }
}

/// Fork the process, detach from the controlling terminal, redirect stdio,
/// and write a PID file.  Must be called before the tokio runtime starts.
#[cfg(unix)]
fn daemonize(data_dir: &str) -> anyhow::Result<()> {
    use std::io::Write;
    use std::os::unix::io::IntoRawFd;

    std::fs::create_dir_all(data_dir)?;

    let pid_file = format!("{}/tether.pid", data_dir);
    let log_path = format!("{}/server.log", data_dir);

    // Single-instance check
    if std::path::Path::new(&pid_file).exists() {
        match check_running(&pid_file) {
            Some(pid) => {
                eprintln!("tether-server already running (PID {}).", pid);
                std::process::exit(1);
            }
            None => {
                let _ = std::fs::remove_file(&pid_file);
            }
        }
    }

    // First fork: parent exits so the shell gets its prompt back
    match unsafe { libc::fork() } {
        -1 => anyhow::bail!("fork() failed: {}", std::io::Error::last_os_error()),
        0 => {}
        _ => std::process::exit(0),
    }

    // Create a new session; this process becomes the session leader and loses
    // its controlling terminal.
    if unsafe { libc::setsid() } == -1 {
        anyhow::bail!("setsid() failed: {}", std::io::Error::last_os_error());
    }

    // Second fork: the session leader can theoretically re-acquire a
    // controlling terminal; the grandchild (non-leader) cannot.
    match unsafe { libc::fork() } {
        -1 => anyhow::bail!("second fork() failed: {}", std::io::Error::last_os_error()),
        0 => {}
        _ => std::process::exit(0),
    }

    // Redirect stdin to /dev/null
    let null_fd = std::fs::File::open("/dev/null")?.into_raw_fd();
    unsafe { libc::dup2(null_fd, libc::STDIN_FILENO) };
    unsafe { libc::close(null_fd) };

    // Redirect stdout + stderr to the log file
    let log_fd = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)?
        .into_raw_fd();
    unsafe {
        libc::dup2(log_fd, libc::STDOUT_FILENO);
        libc::dup2(log_fd, libc::STDERR_FILENO);
        libc::close(log_fd);
    }

    // Write PID file for the final daemon process
    let daemon_pid = unsafe { libc::getpid() };
    let mut f = std::fs::File::create(&pid_file)?;
    writeln!(f, "{}", daemon_pid)?;

    Ok(())
}
