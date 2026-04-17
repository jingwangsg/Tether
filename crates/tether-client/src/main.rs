use std::io::{self, Read};
use std::mem::MaybeUninit;
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
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

const MAX_RECONNECT_DELAY_SECS: u64 = 30;

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

    #[arg(long)]
    offset: Option<u64>,

    #[arg(long)]
    tail_bytes: Option<u64>,

    #[arg(long)]
    metadata_path: Option<PathBuf>,
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
    let stdin_fd = io::stdin().as_raw_fd();
    let stdout_fd = io::stdout().as_raw_fd();
    let _raw_mode = RawModeGuard::new(stdin_fd).context("failed to enable raw mode")?;
    let metadata_logger = MetadataLogger::new(args.metadata_path.clone())?;

    let (input_tx, mut input_rx) = tokio::sync::mpsc::unbounded_channel::<ClientMessage>();
    let input_tx_reader = input_tx.clone();
    let metadata_logger_reader = metadata_logger.clone();
    std::thread::spawn(move || stdin_reader_loop(input_tx_reader, metadata_logger_reader));

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
    let mut acked_offset = args.offset.unwrap_or_default();
    let mut reconnect_attempts = 0u32;

    loop {
        let ws_url = build_session_ws_url(
            &args.server,
            &args.session,
            args.token.as_deref(),
            Some(acked_offset),
            args.tail_bytes,
        )?;
        let (stream, _) = match connect_async(ws_url.as_str()).await {
            Ok(result) => {
                reconnect_attempts = 0;
                result
            }
            Err(error) if is_permanent_connect_error(&error) => {
                return Err(error).with_context(|| format!("failed to connect to {ws_url}"));
            }
            Err(_) => {
                tokio::time::sleep(reconnect_delay(reconnect_attempts)).await;
                reconnect_attempts += 1;
                continue;
            }
        };

        let (mut ws_write, mut ws_read) = stream.split();
        if let Some((cols, rows)) = current_winsize(stdout_fd).or_else(|| current_winsize(stdin_fd))
        {
            let _ = input_tx.send(ClientMessage::Resize { cols, rows });
        }

        let mut should_reconnect = false;
        loop {
            tokio::select! {
                Some(message) = input_rx.recv() => {
                    if ws_write
                        .send(Message::Text(message.into_text().into()))
                        .await
                        .is_err()
                    {
                        should_reconnect = true;
                        break;
                    }
                }
                message = ws_read.next() => {
                    let Some(message) = message else {
                        should_reconnect = true;
                        break;
                    };
                    match message {
                        Ok(Message::Text(text)) => {
                            if handle_server_message(
                                &text,
                                &mut stdout,
                                &mut exit_code,
                                &mut saw_exit,
                                &mut acked_offset,
                                metadata_logger.as_ref(),
                            ).await? {
                                break;
                            }
                        }
                        Ok(Message::Binary(bytes)) => {
                            if let Some(logger) = metadata_logger.as_ref() {
                                logger.write_protocol_trace("ws_to_stdout", &bytes)?;
                            }
                            stdout
                                .write_all(&bytes)
                                .await
                                .context("failed to write websocket bytes to stdout")?;
                            stdout.flush().await.context("failed to flush stdout")?;
                            acked_offset += bytes.len() as u64;
                        }
                        Ok(Message::Ping(payload)) => {
                            if ws_write
                                .send(Message::Pong(payload))
                                .await
                                .is_err()
                            {
                                should_reconnect = true;
                                break;
                            }
                        }
                        Ok(Message::Pong(_)) => {}
                        Ok(Message::Close(_)) => {
                            should_reconnect = true;
                            break;
                        }
                        Ok(Message::Frame(_)) => {}
                        Err(error) => {
                            if is_permanent_stream_error(&error) {
                                return Err(error).context("websocket receive failed");
                            }
                            should_reconnect = true;
                            break;
                        }
                    }
                }
            }
        }

        if saw_exit {
            stdout.flush().await.context("failed to flush stdout")?;
            drop(input_tx);
            ping_task.abort();
            #[cfg(unix)]
            signal_task.abort();
            return Ok(exit_code);
        }

        if !should_reconnect {
            tokio::time::sleep(reconnect_delay(reconnect_attempts)).await;
        } else {
            tokio::time::sleep(reconnect_delay(reconnect_attempts)).await;
        }
        reconnect_attempts += 1;
    }

    #[allow(unreachable_code)]
    {
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
}

async fn handle_server_message<W: AsyncWrite + Unpin>(
    raw: &str,
    stdout: &mut W,
    exit_code: &mut i32,
    saw_exit: &mut bool,
    acked_offset: &mut u64,
    metadata_logger: Option<&MetadataLogger>,
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
            if let Some(logger) = metadata_logger {
                logger.write_protocol_trace("ws_to_stdout", &data)?;
            }
            stdout
                .write_all(&data)
                .await
                .context("failed to write server output")?;
            stdout.flush().await.context("failed to flush stdout")?;
            *acked_offset += data.len() as u64;
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
        "scrollback_info" => {
            if let Some(logger) = metadata_logger {
                let total_bytes = json
                    .get("total_bytes")
                    .and_then(|v| v.as_u64())
                    .context("scrollback_info missing total_bytes")?;
                let loaded_from = json
                    .get("loaded_from")
                    .and_then(|v| v.as_u64())
                    .context("scrollback_info missing loaded_from")?;
                logger.write_scrollback_info(total_bytes, loaded_from)?;
            }
            Ok(false)
        }
        _ => Ok(false),
    }
}

#[derive(Clone)]
struct MetadataLogger {
    file: Arc<Mutex<std::fs::File>>,
}

impl MetadataLogger {
    fn new(path: Option<PathBuf>) -> Result<Option<Self>> {
        let Some(path) = path else {
            return Ok(None);
        };
        if let Some(parent) = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
        {
            std::fs::create_dir_all(parent).with_context(|| {
                format!(
                    "failed to create metadata parent directory {}",
                    parent.display()
                )
            })?;
        }
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .with_context(|| format!("failed to open metadata log {}", path.display()))?;
        Ok(Some(Self {
            file: Arc::new(Mutex::new(file)),
        }))
    }

    fn write_scrollback_info(&self, total_bytes: u64, loaded_from: u64) -> Result<()> {
        let mut file = self
            .file
            .lock()
            .map_err(|_| anyhow::anyhow!("metadata log mutex poisoned"))?;
        serde_json::to_writer(
            &mut *file,
            &json!({
                "type": "scrollback_info",
                "total_bytes": total_bytes,
                "loaded_from": loaded_from,
            }),
        )
        .context("failed to serialize metadata event")?;
        use std::io::Write as _;
        file.write_all(b"\n")
            .context("failed to terminate metadata event")?;
        file.flush().context("failed to flush metadata log")?;
        Ok(())
    }

    fn write_protocol_trace(&self, dir: &str, data: &[u8]) -> Result<()> {
        if !protocol_trace_enabled() {
            return Ok(());
        }

        let mut file = self
            .file
            .lock()
            .map_err(|_| anyhow::anyhow!("metadata log mutex poisoned"))?;
        serde_json::to_writer(
            &mut *file,
            &json!({
                "type": "protocol_trace",
                "timestamp_ms": protocol_trace_timestamp_ms(),
                "dir": dir,
                "len": data.len(),
                "data_b64": base64::engine::general_purpose::STANDARD.encode(data),
                "contains_xtgettcap": contains_xtgettcap(data),
                "contains_focus_seq": contains_focus_seq(data),
                "contains_da_query": contains_da_query(data),
            }),
        )
        .context("failed to serialize metadata event")?;
        use std::io::Write as _;
        file.write_all(b"\n")
            .context("failed to terminate metadata event")?;
        file.flush().context("failed to flush metadata log")?;
        Ok(())
    }
}

fn protocol_trace_enabled() -> bool {
    std::env::var_os("TETHER_PROTOCOL_TRACE").is_some_and(|value| !value.is_empty() && value != "0")
}

fn protocol_trace_timestamp_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or_default()
}

fn contains_xtgettcap(data: &[u8]) -> bool {
    let lower = ascii_lowercase_bytes(data);
    lower
        .windows(b"\x1bp1+r".len())
        .any(|window| window == b"\x1bp1+r")
        || lower
            .windows(b"\x1bp1$r".len())
            .any(|window| window == b"\x1bp1$r")
        || lower.windows(b"1+r".len()).any(|window| window == b"1+r")
        || lower
            .windows(b"696e646e".len())
            .any(|window| window == b"696e646e")
}

fn contains_focus_seq(data: &[u8]) -> bool {
    let lower = ascii_lowercase_bytes(data);
    lower
        .windows(b"\x1b[?1004h".len())
        .any(|window| window == b"\x1b[?1004h")
        || lower
            .windows(b"\x1b[?1004l".len())
            .any(|window| window == b"\x1b[?1004l")
}

fn contains_da_query(data: &[u8]) -> bool {
    data.windows(b"\x1b[c".len())
        .any(|window| window == b"\x1b[c")
        || data
            .windows(b"\x1b[>0c".len())
            .any(|window| window == b"\x1b[>0c")
        || data
            .windows(b"\x1b[>c".len())
            .any(|window| window == b"\x1b[>c")
}

fn ascii_lowercase_bytes(data: &[u8]) -> Vec<u8> {
    data.iter().map(|byte| byte.to_ascii_lowercase()).collect()
}

fn stdin_reader_loop(
    sender: tokio::sync::mpsc::UnboundedSender<ClientMessage>,
    metadata_logger: Option<MetadataLogger>,
) {
    let mut stdin = io::stdin();
    let mut buf = [0u8; 4096];

    loop {
        match stdin.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if forward_stdin_chunk(&sender, &buf[..n], metadata_logger.as_ref()).is_err() {
                    break;
                }
            }
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
}

fn forward_stdin_chunk(
    sender: &tokio::sync::mpsc::UnboundedSender<ClientMessage>,
    data: &[u8],
    metadata_logger: Option<&MetadataLogger>,
) -> Result<()> {
    if let Some(logger) = metadata_logger {
        logger.write_protocol_trace("stdin_to_ws", data)?;
    }
    sender
        .send(ClientMessage::Input(data.to_vec()))
        .map_err(|_| anyhow::anyhow!("failed to forward stdin chunk"))?;
    Ok(())
}

fn build_session_ws_url(
    server: &str,
    session: &str,
    token: Option<&str>,
    offset: Option<u64>,
    tail_bytes: Option<u64>,
) -> Result<Url> {
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

    if token.is_some() || offset.unwrap_or_default() > 0 || tail_bytes.unwrap_or_default() > 0 {
        let mut query_pairs = url.query_pairs_mut();
        if let Some(token) = token {
            query_pairs.append_pair("token", token);
        }
        if let Some(offset) = offset.filter(|offset| *offset > 0) {
            query_pairs.append_pair("offset", &offset.to_string());
        }
        if let Some(tail_bytes) = tail_bytes.filter(|tail_bytes| *tail_bytes > 0) {
            query_pairs.append_pair("tail_bytes", &tail_bytes.to_string());
        }
    }

    Ok(url)
}

fn reconnect_delay(attempt: u32) -> Duration {
    let seconds = std::cmp::min(2u64.saturating_pow(attempt), MAX_RECONNECT_DELAY_SECS);
    Duration::from_secs(seconds.max(1))
}

fn is_permanent_connect_error(error: &tokio_tungstenite::tungstenite::Error) -> bool {
    matches!(
        error,
        tokio_tungstenite::tungstenite::Error::Http(response)
            if matches!(
                response.status(),
                tokio_tungstenite::tungstenite::http::StatusCode::NOT_FOUND
                    | tokio_tungstenite::tungstenite::http::StatusCode::GONE
                    | tokio_tungstenite::tungstenite::http::StatusCode::UNAUTHORIZED
                    | tokio_tungstenite::tungstenite::http::StatusCode::FORBIDDEN
            )
    )
}

fn is_permanent_stream_error(error: &tokio_tungstenite::tungstenite::Error) -> bool {
    matches!(
        error,
        tokio_tungstenite::tungstenite::Error::Http(response)
            if matches!(
                response.status(),
                tokio_tungstenite::tungstenite::http::StatusCode::NOT_FOUND
                    | tokio_tungstenite::tungstenite::http::StatusCode::GONE
                    | tokio_tungstenite::tungstenite::http::StatusCode::UNAUTHORIZED
                    | tokio_tungstenite::tungstenite::http::StatusCode::FORBIDDEN
            )
    )
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
    use super::{
        build_session_ws_url, forward_stdin_chunk, handle_server_message, ClientMessage,
        MetadataLogger,
    };
    use base64::Engine;
    use tokio::io::BufWriter;
    use uuid::Uuid;

    #[test]
    fn http_server_becomes_ws() {
        let url = build_session_ws_url("http://localhost:7680", "abc", None, None, None).unwrap();
        assert_eq!(url.as_str(), "ws://localhost:7680/ws/session/abc");
    }

    #[test]
    fn https_server_becomes_wss_with_token() {
        let url = build_session_ws_url(
            "https://example.com",
            "abc",
            Some("hello world"),
            None,
            None,
        )
        .unwrap();
        assert_eq!(
            url.as_str(),
            "wss://example.com/ws/session/abc?token=hello+world"
        );
    }

    #[test]
    fn ws_url_includes_offset_when_present() {
        let url =
            build_session_ws_url("http://localhost:7680", "abc", None, Some(128), None).unwrap();
        assert_eq!(
            url.as_str(),
            "ws://localhost:7680/ws/session/abc?offset=128"
        );
    }

    #[test]
    fn ws_url_includes_tail_bytes_when_present() {
        let url =
            build_session_ws_url("http://localhost:7680", "abc", None, None, Some(512 * 1024))
                .unwrap();
        assert_eq!(
            url.as_str(),
            "ws://localhost:7680/ws/session/abc?tail_bytes=524288"
        );
    }

    #[test]
    fn ws_url_includes_offset_and_tail_bytes_when_present() {
        let url = build_session_ws_url(
            "http://localhost:7680",
            "abc",
            Some("hello world"),
            Some(128),
            Some(512 * 1024),
        )
        .unwrap();
        assert_eq!(
            url.as_str(),
            "ws://localhost:7680/ws/session/abc?token=hello+world&offset=128&tail_bytes=524288"
        );
    }

    #[tokio::test]
    async fn session_event_exited_returns_true_and_sets_exit_code() {
        let mut stdout = BufWriter::new(tokio::io::sink());
        let mut exit_code = 1;
        let mut saw_exit = false;
        let mut acked_offset = 0u64;

        let should_exit = handle_server_message(
            r#"{"type":"session_event","event":"exited","exit_code":42}"#,
            &mut stdout,
            &mut exit_code,
            &mut saw_exit,
            &mut acked_offset,
            None,
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
        let mut acked_offset = 0u64;

        let should_exit = handle_server_message(
            r#"{"type":"foreground_changed","session_id":"test-123","process":"codex","osc_title":"· Codex CLI"}"#,
            &mut stdout,
            &mut exit_code,
            &mut saw_exit,
            &mut acked_offset,
            None,
        )
        .await
        .unwrap();

        assert!(!should_exit);
        assert!(!saw_exit);
        assert_eq!(exit_code, 1);
    }

    #[tokio::test]
    async fn scrollback_info_is_written_to_metadata_log() {
        let metadata_path =
            std::env::temp_dir().join(format!("tether-client-metadata-{}.jsonl", Uuid::new_v4()));
        let logger = MetadataLogger::new(Some(metadata_path.clone())).unwrap();
        let mut stdout = BufWriter::new(tokio::io::sink());
        let mut exit_code = 1;
        let mut saw_exit = false;
        let mut acked_offset = 0u64;

        let should_exit = handle_server_message(
            r#"{"type":"scrollback_info","total_bytes":1000,"loaded_from":500}"#,
            &mut stdout,
            &mut exit_code,
            &mut saw_exit,
            &mut acked_offset,
            logger.as_ref(),
        )
        .await
        .unwrap();

        let contents = std::fs::read_to_string(&metadata_path).unwrap();
        let line = contents.lines().next().unwrap();
        let value: serde_json::Value = serde_json::from_str(line).unwrap();
        assert!(!should_exit);
        assert_eq!(value["type"], "scrollback_info");
        assert_eq!(value["total_bytes"], 1000);
        assert_eq!(value["loaded_from"], 500);
        std::fs::remove_file(metadata_path).ok();
    }

    #[tokio::test]
    async fn output_protocol_trace_is_written_to_metadata_log_when_enabled() {
        let metadata_path = std::env::temp_dir().join(format!(
            "tether-client-protocol-trace-{}.jsonl",
            Uuid::new_v4()
        ));
        let logger = MetadataLogger::new(Some(metadata_path.clone())).unwrap();
        let mut stdout = BufWriter::new(tokio::io::sink());
        let mut exit_code = 1;
        let mut saw_exit = false;
        let mut acked_offset = 0u64;
        let original_trace = std::env::var_os("TETHER_PROTOCOL_TRACE");
        std::env::set_var("TETHER_PROTOCOL_TRACE", "1");

        let payload = base64::engine::general_purpose::STANDARD
            .encode(b"\x1bP1+r696E646E=5C455B257031256453\x1b\\");
        let raw = format!(r#"{{"type":"output","data":"{payload}"}}"#);
        let should_exit = handle_server_message(
            &raw,
            &mut stdout,
            &mut exit_code,
            &mut saw_exit,
            &mut acked_offset,
            logger.as_ref(),
        )
        .await
        .unwrap();

        let contents = std::fs::read_to_string(&metadata_path).unwrap();
        let protocol_line = contents
            .lines()
            .find(|line| line.contains(r#""type":"protocol_trace""#))
            .expect("expected protocol_trace event");
        let value: serde_json::Value = serde_json::from_str(protocol_line).unwrap();
        assert!(!should_exit);
        assert_eq!(value["dir"], "ws_to_stdout");
        assert_eq!(value["contains_xtgettcap"], true);
        assert_eq!(value["contains_focus_seq"], false);
        assert_eq!(value["contains_da_query"], false);

        if let Some(value) = original_trace {
            std::env::set_var("TETHER_PROTOCOL_TRACE", value);
        } else {
            std::env::remove_var("TETHER_PROTOCOL_TRACE");
        }
        std::fs::remove_file(metadata_path).ok();
    }

    #[test]
    fn stdin_protocol_trace_is_written_to_metadata_log_when_enabled() {
        let metadata_path = std::env::temp_dir().join(format!(
            "tether-client-stdin-trace-{}.jsonl",
            Uuid::new_v4()
        ));
        let logger = MetadataLogger::new(Some(metadata_path.clone())).unwrap();
        let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
        let original_trace = std::env::var_os("TETHER_PROTOCOL_TRACE");
        std::env::set_var("TETHER_PROTOCOL_TRACE", "1");

        forward_stdin_chunk(&sender, b"P1+r696E646E=5C455B257031256453", logger.as_ref()).unwrap();

        let message = receiver.try_recv().expect("expected forwarded input");
        match message {
            ClientMessage::Input(data) => {
                assert_eq!(data, b"P1+r696E646E=5C455B257031256453");
            }
            other => panic!("expected input message, got {other:?}"),
        }

        let contents = std::fs::read_to_string(&metadata_path).unwrap();
        let protocol_line = contents
            .lines()
            .find(|line| line.contains(r#""type":"protocol_trace""#))
            .expect("expected protocol_trace event");
        let value: serde_json::Value = serde_json::from_str(protocol_line).unwrap();
        assert_eq!(value["dir"], "stdin_to_ws");
        assert_eq!(value["contains_xtgettcap"], true);
        assert_eq!(value["len"], 31);

        if let Some(value) = original_trace {
            std::env::set_var("TETHER_PROTOCOL_TRACE", value);
        } else {
            std::env::remove_var("TETHER_PROTOCOL_TRACE");
        }
        std::fs::remove_file(metadata_path).ok();
    }

    #[test]
    fn metadata_logger_creates_parent_directory() {
        let metadata_path = std::env::temp_dir()
            .join(format!("tether-client-{}", Uuid::new_v4()))
            .join("events.jsonl");
        let parent = metadata_path.parent().unwrap().to_path_buf();

        let logger = MetadataLogger::new(Some(metadata_path.clone())).unwrap();
        assert!(logger.is_some());
        assert!(parent.is_dir());

        std::fs::remove_file(metadata_path).ok();
        std::fs::remove_dir(parent).ok();
    }
}
