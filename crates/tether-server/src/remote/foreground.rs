use crate::pty::session::SessionForeground;
use dashmap::DashMap;
use uuid::Uuid;

pub fn update_ssh_foreground_cache(
    cache: &DashMap<Uuid, SessionForeground>,
    session_id: Uuid,
    process: Option<String>,
    osc_title: Option<String>,
    attention_seq: i64,
    attention_ack_seq: i64,
) -> Option<SessionForeground> {
    let next = process.map(|process| SessionForeground {
        process: Some(process),
        osc_title,
        attention_seq,
        attention_ack_seq,
    });

    match &next {
        Some(fg) => {
            cache.insert(session_id, fg.clone());
        }
        None => {
            cache.remove(&session_id);
        }
    }

    next
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stores_remote_state_verbatim() {
        let cache = DashMap::new();
        let session_id = Uuid::new_v4();

        let fg = update_ssh_foreground_cache(
            &cache,
            session_id,
            Some("claude".to_string()),
            Some("· Claude Code".to_string()),
            2,
            1,
        )
        .expect("expected foreground");

        assert_eq!(fg.process.as_deref(), Some("claude"));
        assert_eq!(fg.osc_title.as_deref(), Some("· Claude Code"));
        assert_eq!(fg.attention_seq, 2);
        assert_eq!(fg.attention_ack_seq, 1);
    }

    #[test]
    fn preserves_missing_remote_osc_title_as_none() {
        let cache = DashMap::new();
        let session_id = Uuid::new_v4();

        let fg =
            update_ssh_foreground_cache(&cache, session_id, Some("claude".to_string()), None, 0, 0)
                .expect("expected foreground");

        assert_eq!(fg.process.as_deref(), Some("claude"));
        assert_eq!(fg.osc_title, None);
    }

    #[test]
    fn clears_cache_when_remote_process_is_none() {
        let cache = DashMap::new();
        let session_id = Uuid::new_v4();
        cache.insert(
            session_id,
            SessionForeground {
                process: Some("claude".to_string()),
                osc_title: Some("✱ Claude Code".to_string()),
                attention_seq: 0,
                attention_ack_seq: 0,
            },
        );

        let fg = update_ssh_foreground_cache(&cache, session_id, None, None, 0, 0);

        assert!(fg.is_none());
        assert!(cache.get(&session_id).is_none());
    }
}
