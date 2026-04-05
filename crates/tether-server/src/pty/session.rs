use crate::persistence::scrollback::ScrollbackBuffer;
use crate::pty::osc_parser::OscParser;
use crate::pty::semantic_prompt_parser::{SemanticPromptKind, SemanticPromptParser};
use bytes::Bytes;
use portable_pty::{native_pty_system, Child, CommandBuilder, PtySize};
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use tokio::sync::broadcast;
use uuid::Uuid;

/// Transient foreground process info (not persisted).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionForeground {
    pub process: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub osc_title: Option<String>,
}

impl Default for SessionForeground {
    fn default() -> Self {
        Self {
            process: None,
            osc_title: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CommandPhase {
    Prompt,
    CommandActive,
}

pub struct PtySession {
    pub id: Uuid,
    pub group_id: Mutex<Uuid>,
    pub name: Mutex<String>,
    pub output_tx: broadcast::Sender<Bytes>,
    pub scrollback: Mutex<ScrollbackBuffer>,
    master_writer: Mutex<Box<dyn Write + Send>>,
    child: Mutex<Box<dyn Child + Send + Sync>>,
    pub is_alive: std::sync::atomic::AtomicBool,
    pub cols: std::sync::atomic::AtomicU16,
    pub rows: std::sync::atomic::AtomicU16,
    pub cwd: String,
    pub shell: String,
    // Keep the master PtyPair alive so the FD stays open for resize
    pty_master_fd: Mutex<Option<Box<dyn portable_pty::MasterPty + Send>>>,
    /// Cached foreground process info (transient, not persisted)
    pub foreground: Mutex<SessionForeground>,
    /// Latest window title parsed from OSC escape sequences (for remote process detection)
    osc_title: Mutex<Option<String>>,
    /// Stateful OSC parser, used by reader_loop across chunks
    osc_parser: Mutex<OscParser>,
    /// Stateful OSC 133 parser used for command lifecycle tracking.
    semantic_prompt_parser: Mutex<SemanticPromptParser>,
    /// Sticky OSC title: remembers the last tool name seen in an OSC title.
    /// Cleared only when a non-empty, non-tool title appears (shell reclaimed the title).
    sticky_osc_tool: Mutex<Option<String>>,
    /// Tool detected from PTY output content (e.g., "Claude Code" in welcome banner).
    /// Cleared when alternate screen exits.
    output_detected_tool: Mutex<Option<String>>,
    /// Whether the terminal is currently in alternate screen mode.
    in_alternate_screen: std::sync::atomic::AtomicBool,
    /// Persists the last successfully detected tool while in alternate screen.
    /// Serves as a stable fallback while the terminal is in alternate screen mode.
    /// Cleared only when confirmed outside alt screen with no tool detected.
    last_detected_alt_screen_tool: Mutex<Option<String>>,
    /// Timestamp of the last alt-screen exit, used to maintain the tool cache
    /// for a short grace period while Claude Code is running commands outside alt-screen.
    last_alt_screen_exit_time: Mutex<Option<std::time::Instant>>,
    /// Shell lifecycle phase derived from OSC 133 integration.
    command_phase: Mutex<Option<CommandPhase>>,
    /// Becomes true after we observe any OSC 133 shell-integration marker.
    has_shell_integration: std::sync::atomic::AtomicBool,
    /// Channel to notify the process monitor when a semantic prompt event
    /// has been processed (after all per-chunk state is settled).
    semantic_event_tx: tokio::sync::mpsc::UnboundedSender<Uuid>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PtyTerminalEnv {
    pub vars: Vec<(String, String)>,
}

impl PtySession {
    pub fn spawn(
        id: Uuid,
        group_id: Uuid,
        name: &str,
        shell: &str,
        cwd: &str,
        cols: u16,
        rows: u16,
        scrollback_data_dir: &str,
        scrollback_memory_kb: usize,
        scrollback_disk_max_mb: usize,
        terminal_env: PtyTerminalEnv,
        semantic_event_tx: tokio::sync::mpsc::UnboundedSender<Uuid>,
    ) -> anyhow::Result<Arc<Self>> {
        let pty_system = native_pty_system();
        let pair = pty_system.openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;

        let resolved_cwd = shellexpand::tilde(cwd).to_string();
        let mut cmd = if shell.contains(' ') {
            // Command has arguments — run through login shell
            let login_shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
            let mut c = CommandBuilder::new(&login_shell);
            c.arg("-l");
            c.arg("-c");
            c.arg(shell);
            c
        } else {
            CommandBuilder::new(shell)
        };
        cmd.cwd(&resolved_cwd);
        for (key, value) in terminal_env.vars {
            cmd.env(&key, &value);
        }
        cmd.env_remove("CLAUDECODE");

        let child = pair.slave.spawn_command(cmd)?;
        drop(pair.slave);

        let master_reader = pair.master.try_clone_reader()?;

        let (output_tx, _) = broadcast::channel(256);

        let session_dir = format!("{}/sessions/{}", scrollback_data_dir, id);
        let scrollback =
            ScrollbackBuffer::new(&session_dir, scrollback_memory_kb, scrollback_disk_max_mb);

        // The master itself implements Write, so we use try_clone_reader for reading
        // and a separate writer obtained from the master for writing
        let master_writer: Box<dyn Write + Send> = pair.master.take_writer()?;

        let session = Arc::new(Self {
            id,
            group_id: Mutex::new(group_id),
            name: Mutex::new(name.to_string()),
            output_tx: output_tx.clone(),
            scrollback: Mutex::new(scrollback),
            master_writer: Mutex::new(master_writer),
            child: Mutex::new(child),
            is_alive: std::sync::atomic::AtomicBool::new(true),
            cols: std::sync::atomic::AtomicU16::new(cols),
            rows: std::sync::atomic::AtomicU16::new(rows),
            cwd: resolved_cwd,
            shell: shell.to_string(),
            pty_master_fd: Mutex::new(Some(pair.master)),
            foreground: Mutex::new(SessionForeground::default()),
            osc_title: Mutex::new(None),
            osc_parser: Mutex::new(OscParser::new()),
            semantic_prompt_parser: Mutex::new(SemanticPromptParser::new()),
            sticky_osc_tool: Mutex::new(None),
            output_detected_tool: Mutex::new(None),
            in_alternate_screen: std::sync::atomic::AtomicBool::new(false),
            last_detected_alt_screen_tool: Mutex::new(None),
            last_alt_screen_exit_time: Mutex::new(None),
            command_phase: Mutex::new(None),
            has_shell_integration: std::sync::atomic::AtomicBool::new(false),
            semantic_event_tx,
        });

        // Spawn reader task
        let session_clone = session.clone();
        let tx = output_tx.clone();
        tokio::task::spawn_blocking(move || {
            Self::reader_loop(master_reader, tx, session_clone);
        });

        Ok(session)
    }

    fn reader_loop(
        mut reader: Box<dyn Read + Send>,
        tx: broadcast::Sender<Bytes>,
        session: Arc<PtySession>,
    ) {
        let mut buf = [0u8; 4096];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let data = Bytes::copy_from_slice(&buf[..n]);
                    if let Ok(mut sb) = session.scrollback.lock() {
                        sb.append(&buf[..n]);
                    }
                    // Parse OSC title sequences for remote process detection
                    let mut had_title_change = false;
                    if let Ok(mut parser) = session.osc_parser.lock() {
                        if let Some(title) = parser.feed(&buf[..n]) {
                            if let Ok(mut t) = session.osc_title.lock() {
                                let new_val = if title.is_empty() {
                                    None
                                } else {
                                    Some(title.clone())
                                };
                                if *t != new_val {
                                    had_title_change = true;
                                }
                                *t = new_val;
                            }
                            Self::update_sticky_osc_tool(&session, &title);
                        }
                    }
                    let mut had_semantic_event = false;
                    if let Ok(mut parser) = session.semantic_prompt_parser.lock() {
                        for event in parser.feed(&buf[..n]) {
                            had_semantic_event = true;
                            Self::handle_semantic_prompt(&session, event);
                        }
                    }
                    // Track alternate screen mode and detect tool signatures in output
                    Self::track_alternate_screen(&session, &buf[..n]);
                    Self::detect_tool_in_output(&session, &buf[..n]);
                    // Notify the process monitor AFTER all per-chunk state is settled.
                    // Title changes also trigger re-evaluation because tools like
                    // Claude Code signal their Running/Waiting state via the title.
                    if had_semantic_event || had_title_change {
                        let _ = session.semantic_event_tx.send(session.id);
                    }
                    let _ = tx.send(data);
                }
                Err(_) => break,
            }
        }
        session
            .is_alive
            .store(false, std::sync::atomic::Ordering::Relaxed);
        tracing::info!("PTY session {} reader exited", session.id);
    }

    pub fn write_input(&self, data: &[u8]) -> anyhow::Result<()> {
        let mut writer = self.master_writer.lock().unwrap();
        writer.write_all(data)?;
        writer.flush()?;
        Ok(())
    }

    pub fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<()> {
        if let Some(ref master) = *self.pty_master_fd.lock().unwrap() {
            master.resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })?;
        }
        self.cols.store(cols, std::sync::atomic::Ordering::Relaxed);
        self.rows.store(rows, std::sync::atomic::Ordering::Relaxed);
        Ok(())
    }

    pub fn get_scrollback_snapshot(&self) -> Vec<u8> {
        self.scrollback
            .lock()
            .map(|sb| sb.get_ring_contents())
            .unwrap_or_default()
    }

    pub fn is_alive(&self) -> bool {
        self.is_alive.load(std::sync::atomic::Ordering::Relaxed)
    }

    pub fn kill(&self) {
        if let Ok(mut child) = self.child.lock() {
            child.kill().ok();
        }
    }

    pub fn flush_scrollback(&self) {
        if let Ok(mut sb) = self.scrollback.lock() {
            sb.flush();
        }
    }

    pub fn get_name(&self) -> String {
        self.name.lock().unwrap().clone()
    }

    pub fn set_name(&self, name: &str) {
        *self.name.lock().unwrap() = name.to_string();
    }

    pub fn get_group_id(&self) -> Uuid {
        *self.group_id.lock().unwrap()
    }

    pub fn set_group_id(&self, gid: Uuid) {
        *self.group_id.lock().unwrap() = gid;
    }

    pub fn get_foreground(&self) -> SessionForeground {
        self.foreground.lock().unwrap().clone()
    }

    pub fn get_osc_title(&self) -> Option<String> {
        self.osc_title.lock().ok()?.clone()
    }

    /// Detect the current foreground process.
    /// Uses `MasterPty::process_group_leader()` (calls `tcgetpgrp` internally)
    /// then resolves the process name via `ps`.
    pub fn detect_foreground(&self) -> SessionForeground {
        let process = self.detect_foreground_process();
        let osc_title = self.get_osc_title();
        SessionForeground { process, osc_title }
    }

    pub fn is_known_tool(process: Option<&str>) -> bool {
        matches!(process, Some("claude") | Some("codex"))
    }

    #[allow(dead_code)]
    pub fn has_shell_integration(&self) -> bool {
        self.has_shell_integration
            .load(std::sync::atomic::Ordering::Relaxed)
    }

    pub fn is_in_alternate_screen(&self) -> bool {
        self.in_alternate_screen
            .load(std::sync::atomic::Ordering::Relaxed)
    }

    pub fn set_last_detected_alt_screen_tool(&self, tool: Option<String>) {
        if let Ok(mut t) = self.last_detected_alt_screen_tool.lock() {
            *t = tool;
        }
    }

    fn detect_foreground_process(&self) -> Option<String> {
        self.detect_foreground_from_ps()
            .or_else(|| self.detect_foreground_from_sticky_osc())
            .or_else(|| self.detect_foreground_from_output())
            .or_else(|| self.detect_foreground_from_osc_title())
            .or_else(|| self.detect_foreground_from_alt_screen_cache())
    }

    fn detect_foreground_from_ps(&self) -> Option<String> {
        let master = self.pty_master_fd.lock().ok()?;
        let pgid = master.as_ref()?.process_group_leader()?;
        if pgid <= 0 {
            return None;
        }

        let output = std::process::Command::new("ps")
            .args(["-o", "args=", "-p", &pgid.to_string()])
            .output()
            .ok()?;
        let args = String::from_utf8_lossy(&output.stdout);
        let args_lower = args.to_lowercase();

        for tool in &["claude", "codex"] {
            if args_lower.contains(tool) {
                return Some(tool.to_string());
            }
        }
        None
    }

    fn detect_foreground_from_osc_title(&self) -> Option<String> {
        let title = self.osc_title.lock().ok()?;
        let title_lower = title.as_ref()?.to_lowercase();
        for tool in &["claude", "codex"] {
            if title_lower.contains(tool) {
                return Some(tool.to_string());
            }
        }
        None
    }

    fn detect_foreground_from_alt_screen_cache(&self) -> Option<String> {
        let in_alt = self
            .in_alternate_screen
            .load(std::sync::atomic::Ordering::Relaxed);
        let usable = in_alt || {
            self.last_alt_screen_exit_time
                .lock()
                .ok()
                .and_then(|g| {
                    g.as_ref()
                        .map(|t| t.elapsed() < std::time::Duration::from_secs(5))
                })
                .unwrap_or(false)
        };
        if usable {
            self.last_detected_alt_screen_tool.lock().ok()?.clone()
        } else {
            None
        }
    }

    fn detect_foreground_from_sticky_osc(&self) -> Option<String> {
        self.sticky_osc_tool.lock().ok()?.clone()
    }

    fn detect_foreground_from_output(&self) -> Option<String> {
        self.output_detected_tool.lock().ok()?.clone()
    }

    // --- Reader-loop helpers (called from the PTY reader thread) ---

    const KNOWN_TOOLS: [&str; 2] = ["claude", "codex"];

    /// Update sticky_osc_tool based on the latest OSC title.
    /// - Title contains a tool name -> set sticky
    /// - Title non-empty, no tool -> clear sticky (shell reclaimed the title)
    /// - Title empty -> keep sticky (tool likely cleared its own title)
    fn update_sticky_osc_tool(session: &Arc<PtySession>, title: &str) {
        let title_lower = title.to_lowercase();
        for tool in &Self::KNOWN_TOOLS {
            if title_lower.contains(tool) {
                if let Ok(mut sticky) = session.sticky_osc_tool.lock() {
                    *sticky = Some(tool.to_string());
                }
                return;
            }
        }
        if !title.is_empty() {
            if let Ok(mut sticky) = session.sticky_osc_tool.lock() {
                *sticky = None;
            }
        }
    }

    /// Track alternate screen enter/exit and clear output_detected_tool on exit.
    fn track_alternate_screen(session: &Arc<PtySession>, data: &[u8]) {
        let enter = b"\x1b[?1049h";
        let exit = b"\x1b[?1049l";
        let last_enter = data.windows(enter.len()).rposition(|w| w == enter);
        let last_exit = data.windows(exit.len()).rposition(|w| w == exit);
        match (last_enter, last_exit) {
            (Some(e), Some(x)) if e > x => {
                session
                    .in_alternate_screen
                    .store(true, std::sync::atomic::Ordering::Relaxed);
            }
            (Some(_), Some(_)) => {
                session
                    .in_alternate_screen
                    .store(false, std::sync::atomic::Ordering::Relaxed);
                if let Ok(mut tool) = session.output_detected_tool.lock() {
                    *tool = None;
                }
                if let Ok(mut t) = session.last_alt_screen_exit_time.lock() {
                    *t = Some(std::time::Instant::now());
                }
            }
            (Some(_), None) => {
                session
                    .in_alternate_screen
                    .store(true, std::sync::atomic::Ordering::Relaxed);
            }
            (None, Some(_)) => {
                session
                    .in_alternate_screen
                    .store(false, std::sync::atomic::Ordering::Relaxed);
                if let Ok(mut tool) = session.output_detected_tool.lock() {
                    *tool = None;
                }
                if let Ok(mut t) = session.last_alt_screen_exit_time.lock() {
                    *t = Some(std::time::Instant::now());
                }
            }
            (None, None) => {}
        }
    }

    /// Scan PTY output for tool signatures, but only when in alternate screen mode.
    fn detect_tool_in_output(session: &Arc<PtySession>, data: &[u8]) {
        if !session
            .in_alternate_screen
            .load(std::sync::atomic::Ordering::Relaxed)
        {
            return;
        }
        if let Ok(tool) = session.output_detected_tool.lock() {
            if tool.is_some() {
                return;
            }
        }
        let text = String::from_utf8_lossy(data).to_lowercase();
        let detected = if text.contains("claude code") {
            Some("claude")
        } else if text.contains("codex") {
            Some("codex")
        } else {
            None
        };
        if let Some(name) = detected {
            if let Ok(mut tool) = session.output_detected_tool.lock() {
                *tool = Some(name.to_string());
            }
        }
    }

    fn handle_semantic_prompt(session: &Arc<PtySession>, event: SemanticPromptKind) {
        session
            .has_shell_integration
            .store(true, std::sync::atomic::Ordering::Relaxed);
        match event {
            SemanticPromptKind::EndInputStartOutput => {
                Self::set_command_phase(session, Some(CommandPhase::CommandActive));
            }
            SemanticPromptKind::EndCommand { exit_code: _ } => {
                Self::set_command_phase(session, Some(CommandPhase::Prompt));
            }
            SemanticPromptKind::FreshLineNewPrompt
            | SemanticPromptKind::PromptStart
            | SemanticPromptKind::EndPromptStartInput
            | SemanticPromptKind::EndPromptStartInputTerminateEol
            | SemanticPromptKind::FreshLine
            | SemanticPromptKind::NewCommand => {
                Self::set_command_phase(session, Some(CommandPhase::Prompt));
            }
        }
    }

    fn set_command_phase(session: &Arc<PtySession>, phase: Option<CommandPhase>) {
        if let Ok(mut current_phase) = session.command_phase.lock() {
            if *current_phase == phase {
                return;
            }
            *current_phase = phase;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::SessionForeground;

    #[test]
    fn session_foreground_serializes_with_osc_title() {
        let fg = SessionForeground {
            process: Some("claude".to_string()),
            osc_title: Some("· Claude Code".to_string()),
        };
        let json = serde_json::to_value(&fg).unwrap();
        assert_eq!(json["process"], "claude");
        assert_eq!(json["osc_title"], "· Claude Code");
    }

    #[test]
    fn session_foreground_skips_osc_title_when_none() {
        let fg = SessionForeground {
            process: Some("claude".to_string()),
            osc_title: None,
        };
        let json = serde_json::to_value(&fg).unwrap();
        assert_eq!(json["process"], "claude");
        assert!(
            json.get("osc_title").is_none(),
            "osc_title should be omitted when None"
        );
    }
}
