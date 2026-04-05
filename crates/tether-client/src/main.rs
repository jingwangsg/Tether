use std::io::{self, Read};
use std::mem::MaybeUninit;
use std::os::fd::AsRawFd;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use base64::Engine;
use clap::{Parser, Subcommand};
use futures::{SinkExt, StreamExt};
use serde_json::json;
use tokio::io::{AsyncWrite, AsyncWriteExt, BufWriter};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use url::Url;

#[derive(Debug, Parser)]
#[command(
    name = "tether-client",
    version,
    about = "Attach a local TTY to a tether-server session"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Attach stdin/stdout to a running tether-server session.
    Attach(AttachArgs),
}

#[derive(Debug, clap::Args)]
struct AttachArgs {
    #[arg(long)]
    server: String,

    #[arg(long)]
    session: String,

    #[arg(long)]
    token: Option<String>,
}

#[derive(Debug)]
enum ClientMessage {
    Input(Vec<u8>),
    Resize { cols: u16, rows: u16 },
    Ping,
}

impl ClientMessage {
    fn into_text(self) -> String {
        match self {
            Self::Input(data) => json!({
                "type": "input",
                "data": base64::engine::general_purpose::STANDARD.encode(data),
            })
            .to_string(),
            Self::Resize { cols, rows } => json!({
                "type": "resize",
                "cols": cols,
                "rows": rows,
            })
            .to_string(),
            Self::Ping => json!({ "type": "ping" }).to_string(),
        }
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let code = match cli.command {
        Command::Attach(args) => run_attach(args).await?,
    };
    std::process::exit(code);
}

async fn run_attach(args: AttachArgs) -> Result<i32> {
    let ws_url = build_session_ws_url(&args.server, &args.session, args.token.as_deref())?;
    let stdin_fd = io::stdin().as_raw_fd();
    let stdout_fd = io::stdout().as_raw_fd();
    let _raw_mode = RawModeGuard::new(stdin_fd).context("failed to enable raw mode")?;

    let (stream, _) = connect_async(ws_url.as_str())
        .await
        .with_context(|| format!("failed to connect to {ws_url}"))?;
    let (mut ws_write, mut ws_read) = stream.split();

    let (input_tx, mut input_rx) = tokio::sync::mpsc::unbounded_channel::<ClientMessage>();
    let input_tx_reader = input_tx.clone();
    std::thread::spawn(move || stdin_reader_loop(input_tx_reader));

    if let Some((cols, rows)) = current_winsize(stdout_fd).or_else(|| current_winsize(stdin_fd)) {
        let _ = input_tx.send(ClientMessage::Resize { cols, rows });
    }

    #[cfg(unix)]
    let signal_task = {
        let input_tx_signal = input_tx.clone();
        tokio::spawn(async move {
            let mut sigwinch =
                match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change())
                {
                    Ok(signal) => signal,
                    Err(_) => return,
                };

            while sigwinch.recv().await.is_some() {
                if let Some((cols, rows)) =
                    current_winsize(stdout_fd).or_else(|| current_winsize(stdin_fd))
                {
                    if input_tx_signal
                        .send(ClientMessage::Resize { cols, rows })
                        .is_err()
                    {
                        break;
                    }
                }
            }
        })
    };

    let ping_task = {
        let input_tx_ping = input_tx.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(30)).await;
                if input_tx_ping.send(ClientMessage::Ping).is_err() {
                    break;
                }
            }
        })
    };

    let mut stdout = BufWriter::new(tokio::io::stdout());
    let mut exit_code = 1;
    let mut saw_exit = false;

    loop {
        tokio::select! {
            Some(message) = input_rx.recv() => {
                ws_write
                    .send(Message::Text(message.into_text().into()))
                    .await
                    .context("failed to send websocket message")?;
            }
            message = ws_read.next() => {
                let Some(message) = message else { break };
                match message.context("websocket receive failed")? {
                    Message::Text(text) => {
                        if handle_server_message(&text, &mut stdout, &mut exit_code, &mut saw_exit).await?
                        {
                            break;
                        }
                    }
                    Message::Binary(bytes) => {
                        stdout
                            .write_all(&bytes)
                            .await
                            .context("failed to write websocket bytes to stdout")?;
                        stdout.flush().await.context("failed to flush stdout")?;
                    }
                    Message::Ping(payload) => {
                        ws_write
                            .send(Message::Pong(payload))
                            .await
                            .context("failed to reply to ping")?;
                    }
                    Message::Pong(_) => {}
                    Message::Close(_) => break,
                    Message::Frame(_) => {}
                }
            }
        }
    }

    stdout.flush().await.context("failed to flush stdout")?;
    drop(input_tx);
    ping_task.abort();
    #[cfg(unix)]
    signal_task.abort();

    if saw_exit {
        Ok(exit_code)
    } else {
        bail!("session stream ended unexpectedly")
    }
}

async fn handle_server_message<W: AsyncWrite + Unpin>(
    raw: &str,
    stdout: &mut W,
    exit_code: &mut i32,
    saw_exit: &mut bool,
) -> Result<bool> {
    let json: serde_json::Value =
        serde_json::from_str(raw).context("failed to parse server json")?;
    let message_type = json
        .get("type")
        .and_then(|v| v.as_str())
        .unwrap_or_default();

    match message_type {
        "output" | "scrollback" => {
            let encoded = json
                .get("data")
                .and_then(|v| v.as_str())
                .context("server output missing data")?;
            let data = base64::engine::general_purpose::STANDARD
                .decode(encoded)
                .context("failed to decode output payload")?;
            stdout
                .write_all(&data)
                .await
                .context("failed to write server output")?;
            stdout.flush().await.context("failed to flush stdout")?;
            Ok(false)
        }
        "session_event" => {
            if json.get("event").and_then(|v| v.as_str()) == Some("exited") {
                *saw_exit = true;
                *exit_code = json
                    .get("exit_code")
                    .and_then(|v| v.as_i64())
                    .unwrap_or_default() as i32;
                return Ok(true);
            }
            Ok(false)
        }
        "foreground_changed" | "pong" => Ok(false),
        _ => Ok(false),
    }
}

fn stdin_reader_loop(sender: tokio::sync::mpsc::UnboundedSender<ClientMessage>) {
    let mut stdin = io::stdin();
    let mut buf = [0u8; 4096];

    loop {
        match stdin.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if sender
                    .send(ClientMessage::Input(buf[..n].to_vec()))
                    .is_err()
                {
                    break;
                }
            }
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
}

fn build_session_ws_url(server: &str, session: &str, token: Option<&str>) -> Result<Url> {
    let mut url = Url::parse(server).with_context(|| format!("invalid server URL: {server}"))?;
    match url.scheme() {
        "http" => {
            url.set_scheme("ws").expect("http -> ws is always valid");
        }
        "https" => {
            url.set_scheme("wss").expect("https -> wss is always valid");
        }
        "ws" | "wss" => {}
        scheme => bail!("unsupported server URL scheme: {scheme}"),
    }

    url.set_path(&format!("/ws/session/{session}"));
    url.set_query(None);

    if let Some(token) = token {
        url.query_pairs_mut().append_pair("token", token);
    }

    Ok(url)
}

struct RawModeGuard {
    fd: i32,
    original: libc::termios,
    active: bool,
}

impl RawModeGuard {
    fn new(fd: i32) -> io::Result<Self> {
        if unsafe { libc::isatty(fd) } != 1 {
            return Ok(Self {
                fd,
                original: unsafe { std::mem::zeroed() },
                active: false,
            });
        }

        let mut original = MaybeUninit::<libc::termios>::uninit();
        if unsafe { libc::tcgetattr(fd, original.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let original = unsafe { original.assume_init() };
        let mut raw = original;
        unsafe {
            libc::cfmakeraw(&mut raw);
        }
        if unsafe { libc::tcsetattr(fd, libc::TCSANOW, &raw) } != 0 {
            return Err(io::Error::last_os_error());
        }

        Ok(Self {
            fd,
            original,
            active: true,
        })
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        if self.active {
            unsafe {
                libc::tcsetattr(self.fd, libc::TCSANOW, &self.original);
            }
        }
    }
}

fn current_winsize(fd: i32) -> Option<(u16, u16)> {
    if unsafe { libc::isatty(fd) } != 1 {
        return None;
    }

    let mut winsize = MaybeUninit::<libc::winsize>::zeroed();
    if unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, winsize.as_mut_ptr()) } != 0 {
        return None;
    }
    let winsize = unsafe { winsize.assume_init() };
    if winsize.ws_col == 0 || winsize.ws_row == 0 {
        return None;
    }

    Some((winsize.ws_col, winsize.ws_row))
}

#[cfg(test)]
mod tests {
    use super::{build_session_ws_url, handle_server_message};
    use tokio::io::BufWriter;

    #[test]
    fn http_server_becomes_ws() {
        let url = build_session_ws_url("http://localhost:7680", "abc", None).unwrap();
        assert_eq!(url.as_str(), "ws://localhost:7680/ws/session/abc");
    }

    #[test]
    fn https_server_becomes_wss_with_token() {
        let url = build_session_ws_url("https://example.com", "abc", Some("hello world")).unwrap();
        assert_eq!(
            url.as_str(),
            "wss://example.com/ws/session/abc?token=hello+world"
        );
    }

    #[tokio::test]
    async fn session_event_exited_returns_true_and_sets_exit_code() {
        let mut stdout = BufWriter::new(tokio::io::sink());
        let mut exit_code = 1;
        let mut saw_exit = false;

        let should_exit = handle_server_message(
            r#"{"type":"session_event","event":"exited","exit_code":42}"#,
            &mut stdout,
            &mut exit_code,
            &mut saw_exit,
        )
        .await
        .unwrap();

        assert!(should_exit);
        assert!(saw_exit);
        assert_eq!(exit_code, 42);
    }

    #[tokio::test]
    async fn foreground_changed_is_ignored() {
        let mut stdout = BufWriter::new(tokio::io::sink());
        let mut exit_code = 1;
        let mut saw_exit = false;

        let should_exit = handle_server_message(
            r#"{"type":"foreground_changed","session_id":"test-123","process":"codex","osc_title":"· Codex CLI"}"#,
            &mut stdout,
            &mut exit_code,
            &mut saw_exit,
        )
        .await
        .unwrap();

        assert!(!should_exit);
        assert!(!saw_exit);
        assert_eq!(exit_code, 1);
    }
}
