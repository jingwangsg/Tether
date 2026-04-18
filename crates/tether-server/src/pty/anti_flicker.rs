//! Anti-flicker pipeline for PTY output destined for WebSocket clients.
//!
//! Ink-based TUI apps (Codex, Claude Code) repaint the whole screen on every
//! state change, producing rapid bursts of ANSI that — if forwarded
//! chunk-by-chunk to the client — render as visible tearing and half-drawn
//! frames, especially on Android where GPU/frame budget is tight.
//!
//! This module coalesces those bursts with an adaptive time window (16/32/50
//! ms based on inter-event gap) and wraps each coalesced flush in DEC Mode
//! 2026 synchronized-update markers. Terminals that natively support DEC 2026
//! buffer and render the wrapped span atomically; those that do not ignore
//! the markers harmlessly. The client (`SyncBlockParser` in `xterm_terminal_view.dart`)
//! strips the markers, so xterm.dart renders exactly one coalesced chunk per
//! wrapped block.
//!
//! Scrollback persistence remains unaffected — raw bytes are appended to the
//! scrollback buffer inside the reader loop, before they enter this pipeline.

use bytes::{Bytes, BytesMut};
use std::time::{Duration, Instant};
use tokio::sync::{broadcast, mpsc};

/// DEC Mode 2026 synchronized-update start marker (`CSI ? 2026 h`).
pub const SYNC_START: &[u8] = b"\x1b[?2026h";
/// DEC Mode 2026 synchronized-update end marker (`CSI ? 2026 l`).
pub const SYNC_END: &[u8] = b"\x1b[?2026l";

/// Emit immediately when the coalesced buffer reaches this many bytes. Tuned
/// to match `.codeman/src/web/server.ts`'s `BATCH_FLUSH_THRESHOLD` so behaviour
/// is consistent with the reference implementation.
pub const FLUSH_THRESHOLD_BYTES: usize = 32 * 1024;

/// Sender side of the anti-flicker pipeline, handed to the blocking PTY
/// reader so it can forward raw chunks without caring whether the pipeline
/// is enabled.
pub enum OutputSender {
    /// Route through [`batcher_loop`] for coalescing and DEC 2026 wrapping.
    Batcher(mpsc::UnboundedSender<Bytes>),
    /// Bypass: forward raw chunks straight to the WS broadcast channel.
    /// Used when `--no-anti-flicker` is set.
    Direct(broadcast::Sender<Bytes>),
}

impl OutputSender {
    pub fn send(&self, data: Bytes) {
        match self {
            OutputSender::Batcher(tx) => {
                let _ = tx.send(data);
            }
            OutputSender::Direct(tx) => {
                let _ = tx.send(data);
            }
        }
    }
}

/// Consume raw PTY chunks from `rx`, coalesce them with adaptive batching,
/// wrap each flush in DEC Mode 2026 markers, and broadcast on `output_tx`.
///
/// Terminates when `rx` is closed (all senders dropped), flushing any
/// pending bytes first so nothing is lost on shutdown.
pub async fn batcher_loop(
    mut rx: mpsc::UnboundedReceiver<Bytes>,
    output_tx: broadcast::Sender<Bytes>,
) {
    let mut buffer = BytesMut::new();
    let mut last_event: Option<Instant> = None;
    let mut flush_deadline: Option<Instant> = None;

    loop {
        // Capture the deadline by value so the future doesn't hold a borrow
        // of `flush_deadline` while we reassign it in select branches.
        let deadline_snapshot = flush_deadline;
        let sleep_fut = async move {
            if let Some(deadline) = deadline_snapshot {
                tokio::time::sleep_until(deadline.into()).await;
            } else {
                std::future::pending::<()>().await;
            }
        };
        tokio::pin!(sleep_fut);

        tokio::select! {
            maybe_chunk = rx.recv() => match maybe_chunk {
                None => break,
                Some(chunk) => {
                    let now = Instant::now();
                    let gap = last_event
                        .map(|t| now.duration_since(t))
                        .unwrap_or_else(|| Duration::from_secs(60));
                    last_event = Some(now);
                    buffer.extend_from_slice(&chunk);

                    if buffer.len() >= FLUSH_THRESHOLD_BYTES {
                        flush_wrapped(&mut buffer, &output_tx);
                        flush_deadline = None;
                        continue;
                    }

                    // Resetting the deadline on each chunk means rapid bursts
                    // keep pushing the flush further out, matching codeman's
                    // `setTimeout(clearTimeout(...))` pattern.
                    flush_deadline = Some(now + pick_window(gap));
                }
            },
            _ = &mut sleep_fut, if flush_deadline.is_some() => {
                if !buffer.is_empty() {
                    flush_wrapped(&mut buffer, &output_tx);
                }
                flush_deadline = None;
            }
        }
    }

    if !buffer.is_empty() {
        flush_wrapped(&mut buffer, &output_tx);
    }
}

fn pick_window(gap: Duration) -> Duration {
    let gap_ms = gap.as_millis();
    if gap_ms < 10 {
        Duration::from_millis(50)
    } else if gap_ms < 20 {
        Duration::from_millis(32)
    } else {
        Duration::from_millis(16)
    }
}

fn flush_wrapped(buffer: &mut BytesMut, output_tx: &broadcast::Sender<Bytes>) {
    let data = buffer.split();
    let total_len = SYNC_START.len() + data.len() + SYNC_END.len();
    let mut wrapped = BytesMut::with_capacity(total_len);
    wrapped.extend_from_slice(SYNC_START);
    wrapped.extend_from_slice(&data);
    wrapped.extend_from_slice(SYNC_END);
    let _ = output_tx.send(wrapped.freeze());
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::{broadcast, mpsc};

    fn strip_markers(mut bytes: Vec<u8>) -> Vec<u8> {
        // Remove the outermost sync markers if present.
        if bytes.starts_with(SYNC_START) {
            bytes.drain(..SYNC_START.len());
        }
        if bytes.ends_with(SYNC_END) {
            let n = bytes.len();
            bytes.truncate(n - SYNC_END.len());
        }
        bytes
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn coalesces_rapid_chunks_into_one_flush() {
        let (raw_tx, raw_rx) = mpsc::unbounded_channel();
        let (out_tx, mut out_rx) = broadcast::channel(16);
        let task = tokio::spawn(batcher_loop(raw_rx, out_tx));

        // Burst of tiny chunks with zero gap between them. Adaptive batching
        // should coalesce these into a single wrapped frame.
        for i in 0..5 {
            raw_tx.send(Bytes::from(format!("chunk{i}"))).unwrap();
        }
        // Advance virtual time past the 50 ms window so the batcher flushes.
        tokio::time::sleep(Duration::from_millis(80)).await;

        let first = out_rx.recv().await.expect("expected one flush");
        let unwrapped = strip_markers(first.to_vec());
        assert_eq!(unwrapped, b"chunk0chunk1chunk2chunk3chunk4");
        assert!(first.starts_with(SYNC_START));
        assert!(first.ends_with(SYNC_END));
        assert!(out_rx.try_recv().is_err(), "expected exactly one flush");

        drop(raw_tx);
        task.await.unwrap();
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn flushes_immediately_when_threshold_exceeded() {
        let (raw_tx, raw_rx) = mpsc::unbounded_channel();
        let (out_tx, mut out_rx) = broadcast::channel(16);
        let task = tokio::spawn(batcher_loop(raw_rx, out_tx));

        // One 40 KB chunk — above the 32 KB threshold — should flush without
        // waiting for the timer window.
        let big = Bytes::from(vec![b'x'; 40 * 1024]);
        raw_tx.send(big).unwrap();
        tokio::time::sleep(Duration::from_millis(1)).await;

        let frame = out_rx.recv().await.expect("immediate flush");
        let unwrapped = strip_markers(frame.to_vec());
        assert_eq!(unwrapped.len(), 40 * 1024);

        drop(raw_tx);
        task.await.unwrap();
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn quiet_period_chunks_use_short_window() {
        let (raw_tx, raw_rx) = mpsc::unbounded_channel();
        let (out_tx, mut out_rx) = broadcast::channel(16);
        let task = tokio::spawn(batcher_loop(raw_rx, out_tx));

        // First chunk arrives after a "quiet" 60 ms virtual gap (but since
        // last_event starts as None, the real gap used is 60s which picks 16
        // ms). Either way we expect a short window.
        tokio::time::sleep(Duration::from_millis(60)).await;
        raw_tx.send(Bytes::from_static(b"hello")).unwrap();
        tokio::time::sleep(Duration::from_millis(20)).await;

        let frame = out_rx.recv().await.expect("short-window flush");
        let unwrapped = strip_markers(frame.to_vec());
        assert_eq!(unwrapped, b"hello");

        drop(raw_tx);
        task.await.unwrap();
    }

    #[tokio::test(flavor = "current_thread", start_paused = true)]
    async fn flushes_remaining_on_shutdown() {
        let (raw_tx, raw_rx) = mpsc::unbounded_channel();
        let (out_tx, mut out_rx) = broadcast::channel(16);
        let task = tokio::spawn(batcher_loop(raw_rx, out_tx));

        raw_tx.send(Bytes::from_static(b"tail")).unwrap();
        drop(raw_tx);
        task.await.unwrap();

        let frame = out_rx.recv().await.expect("shutdown flush");
        let unwrapped = strip_markers(frame.to_vec());
        assert_eq!(unwrapped, b"tail");
    }
}
