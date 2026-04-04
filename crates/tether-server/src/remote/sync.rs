use crate::persistence::store::{GroupRow, SessionRow, Store};
use crate::pty::session::SessionForeground;
use dashmap::DashMap;
use uuid::Uuid;

/// Reconcile one SSH host's authoritative remote groups and sessions into the
/// local mirror. Remote IDs are preserved locally so every Mac sees the same
/// group/session graph for that host.
pub async fn sync_remote_host(
    db: &Store,
    host_alias: &str,
    tunnel_port: u16,
    ssh_fg: &DashMap<Uuid, SessionForeground>,
) -> anyhow::Result<()> {
    let base = format!("http://127.0.0.1:{tunnel_port}");
    let client = reqwest::Client::new();

    let (groups_resp, sessions_resp) = tokio::try_join!(
        client.get(format!("{base}/api/groups")).send(),
        client.get(format!("{base}/api/sessions")).send(),
    )?;

    let remote_groups: Vec<GroupRow> = groups_resp.error_for_status()?.json().await?;
    let remote_sessions: Vec<SessionRow> = sessions_resp.error_for_status()?.json().await?;
    let existing_session_ids = db.get_remote_session_ids_by_host(host_alias)?;

    for group in order_groups_for_insert(&remote_groups) {
        db.upsert_remote_group_mirror(group, host_alias)?;
    }

    for session in &remote_sessions {
        db.upsert_remote_session_mirror(session)?;
        if let Ok(id) = Uuid::parse_str(&session.id) {
            match &session.foreground_process {
                Some(process) => {
                    let preserved_tool_state = ssh_fg.get(&id).and_then(|existing| {
                        if existing.process.as_deref() == Some(process.as_str()) {
                            existing.tool_state.clone()
                        } else {
                            None
                        }
                    });
                    ssh_fg.insert(
                        id,
                        SessionForeground {
                            process: Some(process.clone()),
                            tool_state: session.tool_state.clone().or(preserved_tool_state),
                        },
                    );
                }
                None => {
                    ssh_fg.remove(&id);
                }
            }
        }
    }

    let remote_session_ids = remote_sessions
        .iter()
        .map(|session| session.id.clone())
        .collect::<Vec<_>>();
    db.prune_remote_session_mirrors(host_alias, &remote_session_ids)?;
    let remote_session_ids_set = remote_session_ids
        .iter()
        .filter_map(|id| Uuid::parse_str(id).ok())
        .collect::<std::collections::HashSet<_>>();
    let stale_fg_ids = existing_session_ids
        .into_iter()
        .filter_map(|id| Uuid::parse_str(&id).ok())
        .filter(|id| !remote_session_ids_set.contains(id))
        .collect::<Vec<_>>();
    for id in stale_fg_ids {
        ssh_fg.remove(&id);
    }

    let remote_group_ids = remote_groups
        .iter()
        .map(|group| group.id.clone())
        .collect::<Vec<_>>();
    db.prune_remote_group_mirrors(host_alias, &remote_group_ids)?;

    Ok(())
}

fn order_groups_for_insert(groups: &[GroupRow]) -> Vec<&GroupRow> {
    let mut remaining = groups.iter().collect::<Vec<_>>();
    let mut inserted = std::collections::HashSet::<&str>::new();
    let mut ordered = Vec::with_capacity(groups.len());

    while !remaining.is_empty() {
        let before = remaining.len();
        let mut idx = 0usize;
        while idx < remaining.len() {
            let parent_ready = remaining[idx]
                .parent_id
                .as_deref()
                .map(|parent| inserted.contains(parent))
                .unwrap_or(true);
            if parent_ready {
                let group = remaining.remove(idx);
                inserted.insert(group.id.as_str());
                ordered.push(group);
            } else {
                idx += 1;
            }
        }

        if remaining.len() == before {
            ordered.extend(remaining.drain(..));
        }
    }

    ordered
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::routing::get;
    use axum::{Json, Router};
    use std::sync::Arc;
    use tokio::sync::Mutex;
    use uuid::Uuid;

    fn test_store() -> Store {
        let store = Store::new(":memory:").unwrap();
        store.init_tables().unwrap();
        store
    }

    async fn start_mock_remote(groups: Vec<GroupRow>, sessions: Vec<SessionRow>) -> u16 {
        start_mutable_mock_remote(groups, sessions).await.0
    }

    async fn start_mutable_mock_remote(
        groups: Vec<GroupRow>,
        sessions: Vec<SessionRow>,
    ) -> (u16, Arc<Mutex<Vec<GroupRow>>>, Arc<Mutex<Vec<SessionRow>>>) {
        #[derive(Clone)]
        struct MockState {
            groups: Arc<Mutex<Vec<GroupRow>>>,
            sessions: Arc<Mutex<Vec<SessionRow>>>,
        }

        async fn list_groups(
            axum::extract::State(state): axum::extract::State<MockState>,
        ) -> Json<Vec<GroupRow>> {
            Json(state.groups.lock().await.clone())
        }

        async fn list_sessions(
            axum::extract::State(state): axum::extract::State<MockState>,
        ) -> Json<Vec<SessionRow>> {
            Json(state.sessions.lock().await.clone())
        }

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let groups = Arc::new(Mutex::new(groups));
        let sessions = Arc::new(Mutex::new(sessions));
        let app = Router::new()
            .route("/api/groups", get(list_groups))
            .route("/api/sessions", get(list_sessions))
            .with_state(MockState {
                groups: groups.clone(),
                sessions: sessions.clone(),
            });
        tokio::spawn(async move {
            axum::serve(listener, app).await.ok();
        });
        (port, groups, sessions)
    }

    fn group_row(id: &str, name: &str, parent_id: Option<&str>, sort_order: i32) -> GroupRow {
        GroupRow {
            id: id.to_string(),
            name: name.to_string(),
            default_cwd: format!("/srv/{name}"),
            sort_order,
            parent_id: parent_id.map(str::to_string),
            ssh_host: None,
            created_at: "2024-01-01T00:00:00Z".to_string(),
            updated_at: "2024-01-02T00:00:00Z".to_string(),
        }
    }

    fn session_row(
        id: &str,
        group_id: &str,
        name: &str,
        sort_order: i32,
        foreground_process: Option<&str>,
    ) -> SessionRow {
        SessionRow {
            id: id.to_string(),
            group_id: group_id.to_string(),
            name: name.to_string(),
            shell: "/bin/bash".to_string(),
            cols: 120,
            rows: 40,
            cwd: format!("/srv/{name}"),
            created_at: "2024-01-01T00:00:00Z".to_string(),
            last_active: "2024-01-02T00:00:00Z".to_string(),
            sort_order,
            is_alive: true,
            foreground_process: foreground_process.map(str::to_string),
            tool_state: None,
            local_group_id: None,
        }
    }

    #[tokio::test]
    async fn sync_remote_host_upserts_and_prunes_mirrors() {
        let store = test_store();
        let ssh_fg = DashMap::new();
        let host = "shared-host";

        let stale_group = store.create_group("stale", "~", None, Some(host)).unwrap();
        store
            .create_session(
                "stale-session",
                &stale_group.id,
                "stale",
                "/bin/sh",
                "~",
                None,
            )
            .unwrap();
        ssh_fg.insert(
            Uuid::parse_str("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa").unwrap(),
            SessionForeground {
                process: Some("codex".to_string()),
                tool_state: None,
            },
        );

        let group = GroupRow {
            id: "11111111-1111-1111-1111-111111111111".to_string(),
            name: "remote".to_string(),
            default_cwd: "/srv/app".to_string(),
            sort_order: 3,
            parent_id: None,
            ssh_host: None,
            created_at: "2024-01-01T00:00:00Z".to_string(),
            updated_at: "2024-01-02T00:00:00Z".to_string(),
        };
        let session = SessionRow {
            id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa".to_string(),
            group_id: group.id.clone(),
            name: "shared".to_string(),
            shell: "/bin/bash".to_string(),
            cols: 100,
            rows: 40,
            cwd: "/srv/app".to_string(),
            created_at: "2024-01-01T00:00:00Z".to_string(),
            last_active: "2024-01-02T00:00:00Z".to_string(),
            sort_order: 7,
            is_alive: true,
            foreground_process: Some("claude".to_string()),
            tool_state: None,
            local_group_id: None,
        };

        let port = start_mock_remote(vec![group.clone()], vec![session.clone()]).await;
        sync_remote_host(&store, host, port, &ssh_fg).await.unwrap();

        let groups = store.get_groups_by_ssh_host(host).unwrap();
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].id, group.id);
        assert_eq!(groups[0].ssh_host.as_deref(), Some(host));

        let sessions = store.list_sessions().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, session.id);
        assert_eq!(sessions[0].group_id, group.id);
        assert_eq!(sessions[0].sort_order, 7);

        let fg = ssh_fg
            .get(&Uuid::parse_str(&session.id).unwrap())
            .map(|entry| entry.value().clone());
        assert_eq!(
            fg.as_ref().and_then(|entry| entry.process.as_deref()),
            Some("claude")
        );
        assert!(store.get_group(&stale_group.id).unwrap().is_none());
    }

    #[tokio::test]
    async fn sync_remote_host_reconciles_nested_group_trees_and_out_of_band_changes() {
        let store = test_store();
        let ssh_fg = DashMap::new();
        let host = "shared-host";

        let parent = group_row("11111111-1111-1111-1111-111111111111", "parent", None, 0);
        let child = group_row(
            "22222222-2222-2222-2222-222222222222",
            "child",
            Some(&parent.id),
            1,
        );
        let obsolete = group_row("33333333-3333-3333-3333-333333333333", "obsolete", None, 2);
        let session_a = session_row(
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            &parent.id,
            "alpha",
            0,
            Some("claude"),
        );
        let session_b = session_row(
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            &obsolete.id,
            "beta",
            1,
            Some("codex"),
        );

        let (port, groups_state, sessions_state) = start_mutable_mock_remote(
            vec![child.clone(), obsolete.clone(), parent.clone()],
            vec![session_a.clone(), session_b.clone()],
        )
        .await;

        sync_remote_host(&store, host, port, &ssh_fg).await.unwrap();

        let parent_updated = GroupRow {
            name: "parent-renamed".to_string(),
            default_cwd: "/srv/parent-renamed".to_string(),
            updated_at: "2024-01-03T00:00:00Z".to_string(),
            ..parent.clone()
        };
        let child_updated = GroupRow {
            name: "child-renamed".to_string(),
            default_cwd: "/srv/child-renamed".to_string(),
            updated_at: "2024-01-03T00:00:00Z".to_string(),
            ..child.clone()
        };
        let grandchild = group_row(
            "44444444-4444-4444-4444-444444444444",
            "grandchild",
            Some(&child.id),
            3,
        );
        let session_a_moved = SessionRow {
            group_id: grandchild.id.clone(),
            name: "alpha-moved".to_string(),
            sort_order: 5,
            foreground_process: None,
            tool_state: None,
            ..session_a.clone()
        };
        let session_c = session_row(
            "cccccccc-cccc-cccc-cccc-cccccccccccc",
            &child.id,
            "gamma",
            2,
            Some("gemini"),
        );

        *groups_state.lock().await = vec![
            grandchild.clone(),
            child_updated.clone(),
            parent_updated.clone(),
        ];
        *sessions_state.lock().await = vec![session_a_moved.clone(), session_c.clone()];

        sync_remote_host(&store, host, port, &ssh_fg).await.unwrap();

        let groups = store.get_groups_by_ssh_host(host).unwrap();
        assert_eq!(groups.len(), 3);
        let stored_parent = groups.iter().find(|group| group.id == parent.id).unwrap();
        let stored_child = groups.iter().find(|group| group.id == child.id).unwrap();
        let stored_grandchild = groups
            .iter()
            .find(|group| group.id == grandchild.id)
            .unwrap();
        assert_eq!(stored_parent.name, "parent-renamed");
        assert_eq!(stored_child.name, "child-renamed");
        assert_eq!(stored_child.parent_id.as_deref(), Some(parent.id.as_str()));
        assert_eq!(
            stored_grandchild.parent_id.as_deref(),
            Some(child.id.as_str())
        );
        assert!(
            groups.iter().all(|group| group.id != obsolete.id),
            "groups removed remotely should be pruned locally"
        );

        let sessions = store.list_sessions().unwrap();
        assert_eq!(sessions.len(), 2);
        let stored_a = sessions
            .iter()
            .find(|session| session.id == session_a.id)
            .unwrap();
        let stored_c = sessions
            .iter()
            .find(|session| session.id == session_c.id)
            .unwrap();
        assert_eq!(stored_a.group_id, grandchild.id);
        assert_eq!(stored_a.name, "alpha-moved");
        assert_eq!(stored_a.sort_order, 5);
        assert_eq!(stored_c.group_id, child.id);
        assert!(
            sessions.iter().all(|session| session.id != session_b.id),
            "sessions removed remotely should be pruned locally"
        );

        assert!(
            ssh_fg
                .get(&Uuid::parse_str(&session_a.id).unwrap())
                .is_none(),
            "foreground cache should clear when remote no longer reports a process"
        );
        assert!(
            ssh_fg
                .get(&Uuid::parse_str(&session_b.id).unwrap())
                .is_none(),
            "foreground cache should clear for pruned sessions"
        );
        let fg = ssh_fg
            .get(&Uuid::parse_str(&session_c.id).unwrap())
            .map(|entry| entry.value().clone());
        assert_eq!(
            fg.as_ref().and_then(|entry| entry.process.as_deref()),
            Some("gemini")
        );
    }

    #[tokio::test]
    async fn sync_remote_host_preserves_cached_tool_state_when_remote_omits_it() {
        let store = test_store();
        let ssh_fg = DashMap::new();
        let host = "shared-host";

        let group = group_row("11111111-1111-1111-1111-111111111111", "remote", None, 0);
        let session = session_row(
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            &group.id,
            "alpha",
            0,
            Some("claude"),
        );
        ssh_fg.insert(
            Uuid::parse_str(&session.id).unwrap(),
            SessionForeground {
                process: Some("claude".to_string()),
                tool_state: Some(crate::pty::session::ToolState::Running),
            },
        );

        let port = start_mock_remote(vec![group], vec![session]).await;
        sync_remote_host(&store, host, port, &ssh_fg).await.unwrap();

        let fg = ssh_fg
            .get(&Uuid::parse_str("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa").unwrap())
            .map(|entry| entry.value().clone())
            .expect("expected cached foreground");
        assert_eq!(fg.process.as_deref(), Some("claude"));
        assert_eq!(fg.tool_state, Some(crate::pty::session::ToolState::Running));
    }
}
