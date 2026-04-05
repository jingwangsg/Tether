use crate::pty::session::{SessionForeground, ToolState};
use crate::state::AppState;
use serde::{Deserialize, Serialize};
use std::time::{Duration, Instant};
use uuid::Uuid;

const IDLE_TO_WAITING_GRACE: Duration = Duration::from_secs(1);
const IDLE_TO_RUNNING_GRACE: Duration = Duration::from_millis(250);
const WAITING_TO_RUNNING_GRACE: Duration = Duration::from_millis(250);
const RUNNING_TO_WAITING_GRACE: Duration = Duration::from_secs(2);
const TO_IDLE_GRACE: Duration = Duration::from_secs(1);
const MIN_COMPLETION_RUNNING: Duration = Duration::from_secs(3);
const TICK_INTERVAL: Duration = Duration::from_millis(250);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct SessionAttentionState {
    #[serde(default)]
    pub needs_attention: bool,
    #[serde(default)]
    pub attention_seq: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attention_updated_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct SessionStatusSnapshot {
    pub process: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_state: Option<ToolState>,
    #[serde(default)]
    pub needs_attention: bool,
    #[serde(default)]
    pub attention_seq: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attention_updated_at: Option<String>,
}

impl SessionStatusSnapshot {
    pub fn from_parts(foreground: SessionForeground, attention: SessionAttentionState) -> Self {
        Self {
            process: foreground.process,
            tool_state: foreground.tool_state,
            needs_attention: attention.needs_attention,
            attention_seq: attention.attention_seq,
            attention_updated_at: attention.attention_updated_at,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StableToolStatus {
    Idle,
    Running,
    Waiting,
}

impl StableToolStatus {
    fn from_foreground(foreground: &SessionForeground) -> Self {
        if !crate::pty::session::PtySession::is_known_tool(foreground.process.as_deref()) {
            return Self::Idle;
        }

        match foreground.tool_state {
            Some(ToolState::Running) => Self::Running,
            Some(ToolState::Waiting) | None => Self::Waiting,
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct PendingTransition {
    target: StableToolStatus,
    since: Instant,
}

#[derive(Debug, Clone)]
pub struct SessionAttentionTracker {
    initialized: bool,
    stable_status: StableToolStatus,
    stable_since: Instant,
    running_since: Option<Instant>,
    candidate: Option<PendingTransition>,
    seen_rearm_epoch: u64,
    pending_rearm_epoch: Option<u64>,
    armed_rearm_epoch: Option<u64>,
}

impl SessionAttentionTracker {
    fn new(now: Instant) -> Self {
        Self {
            initialized: false,
            stable_status: StableToolStatus::Idle,
            stable_since: now,
            running_since: None,
            candidate: None,
            seen_rearm_epoch: 0,
            pending_rearm_epoch: None,
            armed_rearm_epoch: None,
        }
    }

    fn observe(
        &mut self,
        raw_status: StableToolStatus,
        rearm_epoch: Option<u64>,
        now: Instant,
    ) -> AttentionAdvance {
        if !self.initialized {
            self.initialized = true;
            if let Some(epoch) = rearm_epoch {
                self.seen_rearm_epoch = epoch;
            }
        } else {
            self.observe_rearm_epoch(rearm_epoch);
        }
        let mut advance = self.advance(now);
        if raw_status == self.stable_status {
            self.candidate = None;
            return advance;
        }

        match self.candidate {
            Some(candidate) if candidate.target == raw_status => {
                advance.merge(self.advance(now));
                advance
            }
            _ => {
                self.candidate = Some(PendingTransition {
                    target: raw_status,
                    since: now,
                });
                advance.merge(self.advance(now));
                advance
            }
        }
    }

    fn tick(&mut self, now: Instant) -> AttentionAdvance {
        self.advance(now)
    }

    fn advance(&mut self, now: Instant) -> AttentionAdvance {
        let Some(candidate) = self.candidate else {
            return AttentionAdvance::default();
        };

        let threshold = transition_threshold(self.stable_status, candidate.target);
        if now.duration_since(candidate.since) < threshold {
            return AttentionAdvance::default();
        }

        let previous = self.stable_status;
        let running_duration = self
            .running_since
            .map(|started| now.duration_since(started));
        self.stable_status = candidate.target;
        self.stable_since = now;
        self.candidate = None;

        match candidate.target {
            StableToolStatus::Running => {
                self.running_since = Some(now);
                if self.pending_rearm_epoch.is_some() {
                    self.armed_rearm_epoch = self.pending_rearm_epoch.take();
                }
            }
            StableToolStatus::Idle | StableToolStatus::Waiting => {
                self.running_since = None;
                if candidate.target == StableToolStatus::Idle {
                    self.armed_rearm_epoch = None;
                }
            }
        }

        let completion_triggered = previous == StableToolStatus::Running
            && candidate.target == StableToolStatus::Waiting
            && self.armed_rearm_epoch.is_some()
            && running_duration
                .map(|duration| duration >= MIN_COMPLETION_RUNNING)
                .unwrap_or(false);
        if completion_triggered {
            self.armed_rearm_epoch = None;
        }

        AttentionAdvance {
            completion_triggered,
        }
    }

    fn observe_rearm_epoch(&mut self, rearm_epoch: Option<u64>) {
        let Some(epoch) = rearm_epoch else {
            return;
        };
        if epoch == 0 || epoch <= self.seen_rearm_epoch {
            return;
        }

        self.seen_rearm_epoch = epoch;
        self.pending_rearm_epoch = Some(epoch);
    }
}

#[derive(Debug, Clone, Copy, Default)]
struct AttentionAdvance {
    completion_triggered: bool,
}

impl AttentionAdvance {
    fn merge(&mut self, other: Self) {
        self.completion_triggered |= other.completion_triggered;
    }
}

fn transition_threshold(from: StableToolStatus, to: StableToolStatus) -> Duration {
    match (from, to) {
        (StableToolStatus::Idle, StableToolStatus::Waiting) => IDLE_TO_WAITING_GRACE,
        (StableToolStatus::Idle, StableToolStatus::Running) => IDLE_TO_RUNNING_GRACE,
        (StableToolStatus::Running, StableToolStatus::Waiting) => RUNNING_TO_WAITING_GRACE,
        (StableToolStatus::Running, StableToolStatus::Idle) => TO_IDLE_GRACE,
        (StableToolStatus::Waiting, StableToolStatus::Running) => WAITING_TO_RUNNING_GRACE,
        (StableToolStatus::Waiting, StableToolStatus::Idle) => TO_IDLE_GRACE,
        _ => Duration::ZERO,
    }
}

pub fn observe_foreground(
    state: &AppState,
    session_id: Uuid,
    foreground: &SessionForeground,
    rearm_epoch: Option<u64>,
) {
    let raw_status = StableToolStatus::from_foreground(foreground);
    let now = Instant::now();
    let mut should_publish = false;

    {
        let mut tracker = state
            .inner
            .attention_trackers
            .entry(session_id)
            .or_insert_with(|| SessionAttentionTracker::new(now));
        let advance = tracker.observe(raw_status, rearm_epoch, now);
        if advance.completion_triggered {
            should_publish = trigger_attention(state, session_id);
        }
    }

    if should_publish {
        state.publish_session_status(session_id);
    }
}

pub fn remove_session(state: &AppState, session_id: Uuid) {
    state.inner.attention_trackers.remove(&session_id);
}

pub async fn run_attention_monitor(state: AppState) {
    let mut interval = tokio::time::interval(TICK_INTERVAL);
    interval.tick().await;
    loop {
        interval.tick().await;

        let now = Instant::now();
        let mut completed = Vec::new();
        for mut tracker in state.inner.attention_trackers.iter_mut() {
            if tracker.tick(now).completion_triggered {
                completed.push(*tracker.key());
            }
        }

        for session_id in completed {
            if trigger_attention(&state, session_id) {
                state.publish_session_status(session_id);
            }
        }
    }
}

fn trigger_attention(state: &AppState, session_id: Uuid) -> bool {
    let timestamp = chrono::Utc::now().to_rfc3339();
    match state
        .inner
        .db
        .increment_session_attention(&session_id.to_string(), &timestamp)
    {
        Ok(Some(_)) => true,
        Ok(None) => false,
        Err(error) => {
            tracing::warn!(
                "attention: failed to mark completion for session {}: {}",
                session_id,
                error
            );
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn waiting_fg() -> SessionForeground {
        SessionForeground {
            process: Some("claude".to_string()),
            tool_state: Some(ToolState::Waiting),
        }
    }

    fn running_fg() -> SessionForeground {
        SessionForeground {
            process: Some("claude".to_string()),
            tool_state: Some(ToolState::Running),
        }
    }

    fn baseline_tracker(tracker: &mut SessionAttentionTracker, now: Instant) {
        assert!(
            !tracker
                .observe(StableToolStatus::Idle, Some(0), now)
                .completion_triggered
        );
    }

    #[test]
    fn startup_green_then_waiting_does_not_trigger_completion() {
        let now = Instant::now();
        let mut tracker = SessionAttentionTracker::new(now);

        assert!(
            !tracker
                .observe(
                    StableToolStatus::from_foreground(&running_fg()),
                    Some(1),
                    now
                )
                .completion_triggered
        );
        assert!(
            !tracker
                .tick(now + IDLE_TO_RUNNING_GRACE)
                .completion_triggered
        );
        assert!(
            !tracker
                .observe(
                    StableToolStatus::from_foreground(&waiting_fg()),
                    Some(1),
                    now + IDLE_TO_RUNNING_GRACE + Duration::from_millis(50),
                )
                .completion_triggered
        );
        assert!(
            !tracker
                .tick(
                    now + IDLE_TO_RUNNING_GRACE + RUNNING_TO_WAITING_GRACE + Duration::from_secs(1)
                )
                .completion_triggered
        );
    }

    #[test]
    fn short_waiting_blip_does_not_trigger_completion() {
        let now = Instant::now();
        let mut tracker = SessionAttentionTracker::new(now);
        baseline_tracker(&mut tracker, now);
        tracker.observe(StableToolStatus::Running, Some(1), now);
        tracker.tick(now + IDLE_TO_RUNNING_GRACE);
        tracker.tick(now + IDLE_TO_RUNNING_GRACE + MIN_COMPLETION_RUNNING);

        tracker.observe(
            StableToolStatus::Waiting,
            Some(1),
            now + IDLE_TO_RUNNING_GRACE + MIN_COMPLETION_RUNNING,
        );
        assert!(!tracker
            .tick(
                now + IDLE_TO_RUNNING_GRACE + MIN_COMPLETION_RUNNING + Duration::from_secs(1),
            )
            .completion_triggered);
        assert!(
            !tracker
                .observe(
                    StableToolStatus::Running,
                    Some(1),
                    now + IDLE_TO_RUNNING_GRACE + MIN_COMPLETION_RUNNING + Duration::from_secs(1),
                )
                .completion_triggered
        );
    }

    #[test]
    fn long_running_then_waiting_triggers_completion() {
        let now = Instant::now();
        let mut tracker = SessionAttentionTracker::new(now);
        baseline_tracker(&mut tracker, now);
        tracker.observe(StableToolStatus::Running, Some(1), now);
        tracker.tick(now + IDLE_TO_RUNNING_GRACE);
        tracker.tick(now + IDLE_TO_RUNNING_GRACE + MIN_COMPLETION_RUNNING);
        tracker.observe(
            StableToolStatus::Waiting,
            Some(1),
            now + IDLE_TO_RUNNING_GRACE + MIN_COMPLETION_RUNNING,
        );

        assert!(
            tracker
                .tick(
                    now + IDLE_TO_RUNNING_GRACE + MIN_COMPLETION_RUNNING + RUNNING_TO_WAITING_GRACE,
                )
                .completion_triggered
        );
    }

    #[test]
    fn completion_requires_new_rearm_epoch_before_triggering_again() {
        let now = Instant::now();
        let mut tracker = SessionAttentionTracker::new(now);
        baseline_tracker(&mut tracker, now);

        tracker.observe(StableToolStatus::Running, Some(1), now);
        tracker.tick(now + IDLE_TO_RUNNING_GRACE);
        tracker.tick(now + IDLE_TO_RUNNING_GRACE + MIN_COMPLETION_RUNNING);
        tracker.observe(
            StableToolStatus::Waiting,
            Some(1),
            now + IDLE_TO_RUNNING_GRACE + MIN_COMPLETION_RUNNING,
        );
        assert!(
            tracker
                .tick(
                    now + IDLE_TO_RUNNING_GRACE + MIN_COMPLETION_RUNNING + RUNNING_TO_WAITING_GRACE,
                )
                .completion_triggered
        );

        assert!(
            !tracker
                .observe(
                    StableToolStatus::Running,
                    Some(1),
                    now + IDLE_TO_RUNNING_GRACE
                        + MIN_COMPLETION_RUNNING
                        + RUNNING_TO_WAITING_GRACE
                        + WAITING_TO_RUNNING_GRACE,
                )
                .completion_triggered
        );
        assert!(
            !tracker
                .tick(
                    now + IDLE_TO_RUNNING_GRACE
                        + MIN_COMPLETION_RUNNING
                        + RUNNING_TO_WAITING_GRACE
                        + WAITING_TO_RUNNING_GRACE
                        + MIN_COMPLETION_RUNNING,
                )
                .completion_triggered
        );
        tracker.observe(
            StableToolStatus::Waiting,
            Some(1),
            now + IDLE_TO_RUNNING_GRACE
                + MIN_COMPLETION_RUNNING
                + RUNNING_TO_WAITING_GRACE
                + WAITING_TO_RUNNING_GRACE
                + MIN_COMPLETION_RUNNING,
        );
        assert!(
            !tracker
                .tick(
                    now + IDLE_TO_RUNNING_GRACE
                        + MIN_COMPLETION_RUNNING
                        + RUNNING_TO_WAITING_GRACE
                        + WAITING_TO_RUNNING_GRACE
                        + MIN_COMPLETION_RUNNING
                        + RUNNING_TO_WAITING_GRACE,
                )
                .completion_triggered
        );
    }

    #[test]
    fn new_rearm_epoch_allows_a_later_completion() {
        let now = Instant::now();
        let mut tracker = SessionAttentionTracker::new(now);
        baseline_tracker(&mut tracker, now);
        let first_completion_at =
            now + IDLE_TO_RUNNING_GRACE + MIN_COMPLETION_RUNNING + RUNNING_TO_WAITING_GRACE;

        tracker.observe(StableToolStatus::Running, Some(1), now);
        tracker.tick(now + IDLE_TO_RUNNING_GRACE);
        tracker.tick(now + IDLE_TO_RUNNING_GRACE + MIN_COMPLETION_RUNNING);
        tracker.observe(
            StableToolStatus::Waiting,
            Some(1),
            now + IDLE_TO_RUNNING_GRACE + MIN_COMPLETION_RUNNING,
        );
        assert!(tracker.tick(first_completion_at).completion_triggered);

        tracker.observe(
            StableToolStatus::Running,
            Some(2),
            first_completion_at + Duration::from_millis(50),
        );
        let second_running_at =
            first_completion_at + WAITING_TO_RUNNING_GRACE + Duration::from_millis(50);
        tracker.tick(second_running_at);
        tracker.tick(second_running_at + MIN_COMPLETION_RUNNING);
        tracker.observe(
            StableToolStatus::Waiting,
            Some(2),
            second_running_at + MIN_COMPLETION_RUNNING,
        );
        assert!(
            tracker
                .tick(second_running_at + MIN_COMPLETION_RUNNING + RUNNING_TO_WAITING_GRACE)
                .completion_triggered
        );
    }
}
