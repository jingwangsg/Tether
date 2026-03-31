use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use uuid::Uuid;

pub struct Store {
    conn: Mutex<Connection>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GroupRow {
    pub id: String,
    pub name: String,
    pub default_cwd: String,
    pub sort_order: i32,
    pub parent_id: Option<String>,
    pub ssh_host: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionRow {
    pub id: String,
    pub group_id: String,
    pub name: String,
    pub shell: String,
    pub cols: u16,
    pub rows: u16,
    pub cwd: String,
    pub created_at: String,
    pub last_active: String,
    pub is_alive: bool,
    /// Transient: detected foreground process (e.g. "claude", "codex")
    #[serde(skip_deserializing)]
    pub foreground_process: Option<String>,
}

impl Store {
    pub fn new(path: &str) -> anyhow::Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    pub fn init_tables(&self) -> anyhow::Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS groups (
                id          TEXT PRIMARY KEY,
                name        TEXT NOT NULL,
                default_cwd TEXT NOT NULL DEFAULT '~',
                sort_order  INTEGER NOT NULL DEFAULT 0,
                parent_id   TEXT REFERENCES groups(id),
                created_at  TEXT NOT NULL,
                updated_at  TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sessions (
                id          TEXT PRIMARY KEY,
                group_id    TEXT NOT NULL REFERENCES groups(id),
                name        TEXT NOT NULL,
                shell       TEXT NOT NULL DEFAULT '',
                cols        INTEGER NOT NULL DEFAULT 80,
                rows        INTEGER NOT NULL DEFAULT 24,
                cwd         TEXT NOT NULL,
                created_at  TEXT NOT NULL,
                last_active TEXT NOT NULL,
                is_alive    INTEGER NOT NULL DEFAULT 1
            );
            CREATE TABLE IF NOT EXISTS settings (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_sessions_group_id ON sessions(group_id);",
        )?;
        // Migration: add parent_id column if it doesn't exist (for existing DBs)
        conn.execute_batch(
            "ALTER TABLE groups ADD COLUMN parent_id TEXT REFERENCES groups(id);",
        )
        .ok(); // Ignore error if column already exists
        conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS idx_groups_parent_id ON groups(parent_id);",
        )?;
        // Migration: add sort_order to sessions
        conn.execute_batch(
            "ALTER TABLE sessions ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0;",
        )
        .ok();
        // Migration: add ssh_host to groups
        conn.execute_batch(
            "ALTER TABLE groups ADD COLUMN ssh_host TEXT;",
        )
        .ok();
        Ok(())
    }

    // --- Groups ---

    pub fn list_groups(&self) -> anyhow::Result<Vec<GroupRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, name, default_cwd, sort_order, parent_id, created_at, updated_at, ssh_host FROM groups ORDER BY sort_order, name",
        )?;
        let rows = stmt
            .query_map([], |row| {
                Ok(GroupRow {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    default_cwd: row.get(2)?,
                    sort_order: row.get(3)?,
                    parent_id: row.get(4)?,
                    ssh_host: row.get(7)?,
                    created_at: row.get(5)?,
                    updated_at: row.get(6)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn create_group(
        &self,
        name: &str,
        default_cwd: &str,
        parent_id: Option<&str>,
        ssh_host: Option<&str>,
    ) -> anyhow::Result<GroupRow> {
        let conn = self.conn.lock().unwrap();
        let id = Uuid::new_v4().to_string();
        let now = chrono::Utc::now().to_rfc3339();
        let max_order: i32 = conn
            .query_row("SELECT COALESCE(MAX(sort_order), -1) FROM groups", [], |r| {
                r.get(0)
            })
            .unwrap_or(-1);
        conn.execute(
            "INSERT INTO groups (id, name, default_cwd, sort_order, parent_id, ssh_host, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![id, name, default_cwd, max_order + 1, parent_id, ssh_host, now, now],
        )?;
        Ok(GroupRow {
            id,
            name: name.to_string(),
            default_cwd: default_cwd.to_string(),
            sort_order: max_order + 1,
            parent_id: parent_id.map(|s| s.to_string()),
            ssh_host: ssh_host.map(|s| s.to_string()),
            created_at: now.clone(),
            updated_at: now,
        })
    }

    pub fn update_group(
        &self,
        id: &str,
        name: Option<&str>,
        default_cwd: Option<&str>,
        sort_order: Option<i32>,
        ssh_host: Option<&str>,
    ) -> anyhow::Result<()> {
        let mut sets = Vec::new();
        let mut values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
        let now = chrono::Utc::now().to_rfc3339();

        if let Some(name) = name {
            sets.push("name = ?");
            values.push(Box::new(name.to_string()));
        }
        if let Some(cwd) = default_cwd {
            sets.push("default_cwd = ?");
            values.push(Box::new(cwd.to_string()));
        }
        if let Some(order) = sort_order {
            sets.push("sort_order = ?");
            values.push(Box::new(order));
        }
        if let Some(host) = ssh_host {
            // Empty string means clear the ssh_host
            if host.is_empty() {
                sets.push("ssh_host = NULL");
            } else {
                sets.push("ssh_host = ?");
                values.push(Box::new(host.to_string()));
            }
        }
        if sets.is_empty() {
            return Ok(());
        }
        sets.push("updated_at = ?");
        values.push(Box::new(now));
        values.push(Box::new(id.to_string()));

        let sql = format!(
            "UPDATE groups SET {} WHERE id = ?",
            sets.join(", ")
        );
        let conn = self.conn.lock().unwrap();
        conn.execute(&sql, rusqlite::params_from_iter(values.iter().map(|v| v.as_ref())))?;
        Ok(())
    }

    /// Collect all descendant group IDs (recursive) including the given id itself
    pub fn collect_descendant_ids(&self, id: &str) -> anyhow::Result<Vec<String>> {
        let conn = self.conn.lock().unwrap();
        let mut result = vec![id.to_string()];
        let mut queue = vec![id.to_string()];
        while let Some(parent) = queue.pop() {
            let mut stmt =
                conn.prepare("SELECT id FROM groups WHERE parent_id = ?1")?;
            let children: Vec<String> = stmt
                .query_map(params![parent], |row| row.get(0))?
                .collect::<Result<Vec<_>, _>>()?;
            for child in children {
                result.push(child.clone());
                queue.push(child);
            }
        }
        Ok(result)
    }

    /// Delete a group and ALL its descendants (folders + sessions) recursively.
    /// Wrapped in a transaction to prevent orphaned data on partial failure.
    pub fn delete_group(&self, id: &str) -> anyhow::Result<Vec<String>> {
        let ids = self.collect_descendant_ids(id)?;
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        for gid in &ids {
            tx.execute("DELETE FROM sessions WHERE group_id = ?1", params![gid])?;
        }
        // Delete in reverse order (children first) to respect FK constraints
        for gid in ids.iter().rev() {
            tx.execute("DELETE FROM groups WHERE id = ?1", params![gid])?;
        }
        tx.commit()?;
        Ok(ids)
    }

    /// Check if setting `parent_id` on `group_id` would create a cycle.
    /// Walks ancestors from `parent_id` upward; returns true if `group_id` is found.
    #[allow(dead_code)]
    pub fn would_create_cycle(&self, group_id: &str, parent_id: &str) -> anyhow::Result<bool> {
        let conn = self.conn.lock().unwrap();
        let mut current = Some(parent_id.to_string());
        while let Some(ref pid) = current {
            if pid == group_id {
                return Ok(true);
            }
            current = conn
                .query_row(
                    "SELECT parent_id FROM groups WHERE id = ?1",
                    params![pid],
                    |row| row.get::<_, Option<String>>(0),
                )
                .ok()
                .flatten();
        }
        Ok(false)
    }

    pub fn get_group(&self, id: &str) -> anyhow::Result<Option<GroupRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, name, default_cwd, sort_order, parent_id, created_at, updated_at, ssh_host FROM groups WHERE id = ?1",
        )?;
        let row = stmt
            .query_row(params![id], |row| {
                Ok(GroupRow {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    default_cwd: row.get(2)?,
                    sort_order: row.get(3)?,
                    parent_id: row.get(4)?,
                    ssh_host: row.get(7)?,
                    created_at: row.get(5)?,
                    updated_at: row.get(6)?,
                })
            })
            .ok();
        Ok(row)
    }

    // --- Sessions ---

    pub fn list_sessions(&self) -> anyhow::Result<Vec<SessionRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, group_id, name, shell, cols, rows, cwd, created_at, last_active, is_alive FROM sessions ORDER BY sort_order, created_at",
        )?;
        let rows = stmt
            .query_map([], |row| {
                Ok(SessionRow {
                    id: row.get(0)?,
                    group_id: row.get(1)?,
                    name: row.get(2)?,
                    shell: row.get(3)?,
                    cols: row.get(4)?,
                    rows: row.get(5)?,
                    cwd: row.get(6)?,
                    created_at: row.get(7)?,
                    last_active: row.get(8)?,
                    is_alive: row.get::<_, i32>(9)? != 0,
                    foreground_process: None,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn create_session(
        &self,
        id: &str,
        group_id: &str,
        name: &str,
        shell: &str,
        cwd: &str,
    ) -> anyhow::Result<SessionRow> {
        let conn = self.conn.lock().unwrap();
        let now = chrono::Utc::now().to_rfc3339();
        conn.execute(
            "INSERT INTO sessions (id, group_id, name, shell, cols, rows, cwd, created_at, last_active, is_alive) VALUES (?1, ?2, ?3, ?4, 80, 24, ?5, ?6, ?7, 1)",
            params![id, group_id, name, shell, cwd, now, now],
        )?;
        Ok(SessionRow {
            id: id.to_string(),
            group_id: group_id.to_string(),
            name: name.to_string(),
            shell: shell.to_string(),
            cols: 80,
            rows: 24,
            cwd: cwd.to_string(),
            created_at: now.clone(),
            last_active: now,
            is_alive: true,
            foreground_process: None,
        })
    }

    pub fn update_session_name(&self, id: &str, name: &str) -> anyhow::Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE sessions SET name = ?1 WHERE id = ?2",
            params![name, id],
        )?;
        Ok(())
    }

    pub fn update_session_sort_order(&self, id: &str, sort_order: i32) -> anyhow::Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE sessions SET sort_order = ?1 WHERE id = ?2",
            params![sort_order, id],
        )?;
        Ok(())
    }

    pub fn update_session_group(&self, id: &str, group_id: &str) -> anyhow::Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE sessions SET group_id = ?1 WHERE id = ?2",
            params![group_id, id],
        )?;
        Ok(())
    }

    pub fn update_session_size(&self, id: &str, cols: u16, rows: u16) -> anyhow::Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE sessions SET cols = ?1, rows = ?2 WHERE id = ?3",
            params![cols, rows, id],
        )?;
        Ok(())
    }

    pub fn delete_session(&self, id: &str) -> anyhow::Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM sessions WHERE id = ?1", params![id])?;
        Ok(())
    }

    pub fn delete_all_sessions(&self) -> anyhow::Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM sessions", [])?;
        Ok(())
    }

    pub fn batch_reorder_groups(&self, orders: &[(String, i32)]) -> anyhow::Result<()> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let now = chrono::Utc::now().to_rfc3339();
        for (id, order) in orders {
            tx.execute(
                "UPDATE groups SET sort_order = ?1, updated_at = ?2 WHERE id = ?3",
                params![order, now, id],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn batch_reorder_sessions(&self, orders: &[(String, i32)]) -> anyhow::Result<()> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        for (id, order) in orders {
            tx.execute(
                "UPDATE sessions SET sort_order = ?1 WHERE id = ?2",
                params![order, id],
            )?;
        }
        tx.commit()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn new_store() -> Store {
        let store = Store::new(":memory:").unwrap();
        store.init_tables().unwrap();
        store
    }

    // --- Group CRUD ---

    #[test]
    fn create_and_get_group() {
        let store = new_store();
        let group = store.create_group("dev", "/tmp", None, None).unwrap();
        assert_eq!(group.name, "dev");
        assert_eq!(group.default_cwd, "/tmp");
        assert!(group.parent_id.is_none());

        let fetched = store.get_group(&group.id).unwrap().unwrap();
        assert_eq!(fetched.id, group.id);
        assert_eq!(fetched.name, "dev");
    }

    #[test]
    fn list_groups_empty() {
        let store = new_store();
        let groups = store.list_groups().unwrap();
        assert!(groups.is_empty());
    }

    #[test]
    fn list_groups_returns_all() {
        let store = new_store();
        store.create_group("a", "~", None, None).unwrap();
        store.create_group("b", "~", None, None).unwrap();
        store.create_group("c", "~", None, None).unwrap();
        let groups = store.list_groups().unwrap();
        assert_eq!(groups.len(), 3);
    }

    #[test]
    fn create_group_increments_sort_order() {
        let store = new_store();
        let g1 = store.create_group("first", "~", None, None).unwrap();
        let g2 = store.create_group("second", "~", None, None).unwrap();
        let g3 = store.create_group("third", "~", None, None).unwrap();
        assert_eq!(g1.sort_order, 0);
        assert_eq!(g2.sort_order, 1);
        assert_eq!(g3.sort_order, 2);
    }

    #[test]
    fn update_group_name() {
        let store = new_store();
        let group = store.create_group("old", "~", None, None).unwrap();
        store.update_group(&group.id, Some("new"), None, None, None).unwrap();
        let fetched = store.get_group(&group.id).unwrap().unwrap();
        assert_eq!(fetched.name, "new");
    }

    #[test]
    fn update_group_cwd() {
        let store = new_store();
        let group = store.create_group("g", "/old", None, None).unwrap();
        store.update_group(&group.id, None, Some("/new"), None, None).unwrap();
        let fetched = store.get_group(&group.id).unwrap().unwrap();
        assert_eq!(fetched.default_cwd, "/new");
    }

    #[test]
    fn update_group_sort_order() {
        let store = new_store();
        let group = store.create_group("g", "~", None, None).unwrap();
        store.update_group(&group.id, None, None, Some(99), None).unwrap();
        let fetched = store.get_group(&group.id).unwrap().unwrap();
        assert_eq!(fetched.sort_order, 99);
    }

    #[test]
    fn update_group_noop_with_no_fields() {
        let store = new_store();
        let group = store.create_group("g", "~", None, None).unwrap();
        // Should succeed even with nothing to update
        store.update_group(&group.id, None, None, None, None).unwrap();
        let fetched = store.get_group(&group.id).unwrap().unwrap();
        assert_eq!(fetched.name, "g");
    }

    #[test]
    fn delete_group_basic() {
        let store = new_store();
        let group = store.create_group("doomed", "~", None, None).unwrap();
        let deleted = store.delete_group(&group.id).unwrap();
        assert_eq!(deleted, vec![group.id.clone()]);
        assert!(store.get_group(&group.id).unwrap().is_none());
    }

    #[test]
    fn get_nonexistent_group() {
        let store = new_store();
        assert!(store.get_group("nonexistent-id").unwrap().is_none());
    }

    #[test]
    fn delete_nonexistent_group() {
        let store = new_store();
        // Should succeed (no-op) -- returns vec with just the id itself
        let deleted = store.delete_group("nonexistent-id").unwrap();
        assert_eq!(deleted, vec!["nonexistent-id".to_string()]);
    }

    // --- Nested Groups ---

    #[test]
    fn create_group_with_parent() {
        let store = new_store();
        let parent = store.create_group("parent", "~", None, None).unwrap();
        let child = store.create_group("child", "~", Some(&parent.id), None).unwrap();
        assert_eq!(child.parent_id.as_deref(), Some(parent.id.as_str()));
    }

    #[test]
    fn collect_descendant_ids_single() {
        let store = new_store();
        let g = store.create_group("root", "~", None, None).unwrap();
        let ids = store.collect_descendant_ids(&g.id).unwrap();
        assert_eq!(ids, vec![g.id]);
    }

    #[test]
    fn collect_descendant_ids_tree() {
        let store = new_store();
        let root = store.create_group("root", "~", None, None).unwrap();
        let child1 = store.create_group("c1", "~", Some(&root.id), None).unwrap();
        let child2 = store.create_group("c2", "~", Some(&root.id), None).unwrap();
        let grandchild = store.create_group("gc", "~", Some(&child1.id), None).unwrap();

        let ids = store.collect_descendant_ids(&root.id).unwrap();
        assert_eq!(ids.len(), 4);
        assert!(ids.contains(&root.id));
        assert!(ids.contains(&child1.id));
        assert!(ids.contains(&child2.id));
        assert!(ids.contains(&grandchild.id));
    }

    #[test]
    fn collect_descendant_ids_leaf() {
        let store = new_store();
        let root = store.create_group("root", "~", None, None).unwrap();
        let child = store.create_group("child", "~", Some(&root.id), None).unwrap();
        // Collecting from child should only return child itself
        let ids = store.collect_descendant_ids(&child.id).unwrap();
        assert_eq!(ids, vec![child.id]);
    }

    // --- Recursive Deletion ---

    #[test]
    fn delete_group_cascades_to_children() {
        let store = new_store();
        let root = store.create_group("root", "~", None, None).unwrap();
        let child = store.create_group("child", "~", Some(&root.id), None).unwrap();
        let grandchild = store.create_group("grandchild", "~", Some(&child.id), None).unwrap();

        let deleted = store.delete_group(&root.id).unwrap();
        assert_eq!(deleted.len(), 3);
        assert!(store.get_group(&root.id).unwrap().is_none());
        assert!(store.get_group(&child.id).unwrap().is_none());
        assert!(store.get_group(&grandchild.id).unwrap().is_none());
    }

    #[test]
    fn delete_group_cascades_sessions() {
        let store = new_store();
        let group = store.create_group("g", "~", None, None).unwrap();
        store.create_session("s1", &group.id, "session1", "/bin/sh", "~").unwrap();
        store.create_session("s2", &group.id, "session2", "/bin/sh", "~").unwrap();

        store.delete_group(&group.id).unwrap();
        let sessions = store.list_sessions().unwrap();
        assert!(sessions.is_empty());
    }

    #[test]
    fn delete_group_cascades_nested_sessions() {
        let store = new_store();
        let root = store.create_group("root", "~", None, None).unwrap();
        let child = store.create_group("child", "~", Some(&root.id), None).unwrap();
        store.create_session("s1", &root.id, "s1", "/bin/sh", "~").unwrap();
        store.create_session("s2", &child.id, "s2", "/bin/sh", "~").unwrap();

        store.delete_group(&root.id).unwrap();
        assert!(store.list_sessions().unwrap().is_empty());
        assert!(store.list_groups().unwrap().is_empty());
    }

    // --- Cycle Detection ---

    #[test]
    fn no_cycle_for_unrelated_groups() {
        let store = new_store();
        let a = store.create_group("a", "~", None, None).unwrap();
        let b = store.create_group("b", "~", None, None).unwrap();
        assert!(!store.would_create_cycle(&a.id, &b.id).unwrap());
    }

    #[test]
    fn cycle_self_reference() {
        let store = new_store();
        let a = store.create_group("a", "~", None, None).unwrap();
        // Setting a's parent to a would be a cycle
        assert!(store.would_create_cycle(&a.id, &a.id).unwrap());
    }

    #[test]
    fn cycle_two_level() {
        let store = new_store();
        let parent = store.create_group("parent", "~", None, None).unwrap();
        let child = store.create_group("child", "~", Some(&parent.id), None).unwrap();
        // Setting parent's parent_id to child would create a cycle
        assert!(store.would_create_cycle(&parent.id, &child.id).unwrap());
    }

    #[test]
    fn cycle_three_level() {
        let store = new_store();
        let a = store.create_group("a", "~", None, None).unwrap();
        let b = store.create_group("b", "~", Some(&a.id), None).unwrap();
        let c = store.create_group("c", "~", Some(&b.id), None).unwrap();
        // Setting a's parent_id to c would create a -> b -> c -> a cycle
        assert!(store.would_create_cycle(&a.id, &c.id).unwrap());
        // But setting c's parent to a different unrelated group is fine
        let d = store.create_group("d", "~", None, None).unwrap();
        assert!(!store.would_create_cycle(&c.id, &d.id).unwrap());
    }

    #[test]
    fn no_cycle_for_nonexistent_parent() {
        let store = new_store();
        let a = store.create_group("a", "~", None, None).unwrap();
        // parent_id doesn't exist in DB, so walk stops immediately
        assert!(!store.would_create_cycle(&a.id, "nonexistent").unwrap());
    }

    // --- Batch Reorder Groups ---

    #[test]
    fn batch_reorder_groups_basic() {
        let store = new_store();
        let g1 = store.create_group("a", "~", None, None).unwrap();
        let g2 = store.create_group("b", "~", None, None).unwrap();
        let g3 = store.create_group("c", "~", None, None).unwrap();

        store.batch_reorder_groups(&[
            (g3.id.clone(), 0),
            (g1.id.clone(), 1),
            (g2.id.clone(), 2),
        ]).unwrap();

        let groups = store.list_groups().unwrap();
        assert_eq!(groups[0].id, g3.id);
        assert_eq!(groups[1].id, g1.id);
        assert_eq!(groups[2].id, g2.id);
    }

    #[test]
    fn batch_reorder_groups_empty() {
        let store = new_store();
        store.batch_reorder_groups(&[]).unwrap();
    }

    // --- Session CRUD ---

    #[test]
    fn create_and_list_session() {
        let store = new_store();
        let group = store.create_group("g", "~", None, None).unwrap();
        let session = store.create_session("sid1", &group.id, "my-session", "/bin/bash", "/home").unwrap();
        assert_eq!(session.id, "sid1");
        assert_eq!(session.group_id, group.id);
        assert_eq!(session.name, "my-session");
        assert_eq!(session.shell, "/bin/bash");
        assert_eq!(session.cwd, "/home");
        assert_eq!(session.cols, 80);
        assert_eq!(session.rows, 24);
        assert!(session.is_alive);

        let sessions = store.list_sessions().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, "sid1");
    }

    #[test]
    fn list_sessions_empty() {
        let store = new_store();
        let sessions = store.list_sessions().unwrap();
        assert!(sessions.is_empty());
    }

    #[test]
    fn update_session_name() {
        let store = new_store();
        let group = store.create_group("g", "~", None, None).unwrap();
        store.create_session("s1", &group.id, "old", "/bin/sh", "~").unwrap();
        store.update_session_name("s1", "new").unwrap();
        let sessions = store.list_sessions().unwrap();
        assert_eq!(sessions[0].name, "new");
    }

    #[test]
    fn update_session_sort_order() {
        let store = new_store();
        let group = store.create_group("g", "~", None, None).unwrap();
        store.create_session("s1", &group.id, "s", "/bin/sh", "~").unwrap();
        store.update_session_sort_order("s1", 42).unwrap();
        // Verify by listing (sort_order affects ordering)
        let sessions = store.list_sessions().unwrap();
        assert_eq!(sessions.len(), 1);
    }

    #[test]
    fn update_session_group() {
        let store = new_store();
        let g1 = store.create_group("g1", "~", None, None).unwrap();
        let g2 = store.create_group("g2", "~", None, None).unwrap();
        store.create_session("s1", &g1.id, "s", "/bin/sh", "~").unwrap();
        store.update_session_group("s1", &g2.id).unwrap();
        let sessions = store.list_sessions().unwrap();
        assert_eq!(sessions[0].group_id, g2.id);
    }

    #[test]
    fn delete_session() {
        let store = new_store();
        let group = store.create_group("g", "~", None, None).unwrap();
        store.create_session("s1", &group.id, "s", "/bin/sh", "~").unwrap();
        store.delete_session("s1").unwrap();
        assert!(store.list_sessions().unwrap().is_empty());
    }

    #[test]
    fn delete_nonexistent_session() {
        let store = new_store();
        // Should succeed (no-op)
        store.delete_session("nonexistent").unwrap();
    }

    #[test]
    fn delete_all_sessions() {
        let store = new_store();
        let group = store.create_group("g", "~", None, None).unwrap();
        store.create_session("s1", &group.id, "a", "/bin/sh", "~").unwrap();
        store.create_session("s2", &group.id, "b", "/bin/sh", "~").unwrap();
        store.create_session("s3", &group.id, "c", "/bin/sh", "~").unwrap();
        store.delete_all_sessions().unwrap();
        assert!(store.list_sessions().unwrap().is_empty());
    }

    #[test]
    fn delete_all_sessions_when_empty() {
        let store = new_store();
        store.delete_all_sessions().unwrap();
    }

    // --- Batch Reorder Sessions ---

    #[test]
    fn batch_reorder_sessions_basic() {
        let store = new_store();
        let group = store.create_group("g", "~", None, None).unwrap();
        store.create_session("s1", &group.id, "a", "/bin/sh", "~").unwrap();
        store.create_session("s2", &group.id, "b", "/bin/sh", "~").unwrap();
        store.create_session("s3", &group.id, "c", "/bin/sh", "~").unwrap();

        store.batch_reorder_sessions(&[
            ("s3".to_string(), 0),
            ("s1".to_string(), 1),
            ("s2".to_string(), 2),
        ]).unwrap();

        let sessions = store.list_sessions().unwrap();
        assert_eq!(sessions[0].id, "s3");
        assert_eq!(sessions[1].id, "s1");
        assert_eq!(sessions[2].id, "s2");
    }

    #[test]
    fn batch_reorder_sessions_empty() {
        let store = new_store();
        store.batch_reorder_sessions(&[]).unwrap();
    }

    // --- Session Size ---

    #[test]
    fn update_session_size() {
        let store = new_store();
        let group = store.create_group("g", "~", None, None).unwrap();
        store.create_session("s1", &group.id, "s", "/bin/sh", "~").unwrap();
        store.update_session_size("s1", 120, 40).unwrap();
        let sessions = store.list_sessions().unwrap();
        assert_eq!(sessions[0].cols, 120);
        assert_eq!(sessions[0].rows, 40);
    }

    // --- Multiple groups/sessions interaction ---

    #[test]
    fn sessions_survive_sibling_group_deletion() {
        let store = new_store();
        let g1 = store.create_group("g1", "~", None, None).unwrap();
        let g2 = store.create_group("g2", "~", None, None).unwrap();
        store.create_session("s1", &g1.id, "a", "/bin/sh", "~").unwrap();
        store.create_session("s2", &g2.id, "b", "/bin/sh", "~").unwrap();

        store.delete_group(&g1.id).unwrap();

        let sessions = store.list_sessions().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, "s2");
    }

    #[test]
    fn delete_middle_of_tree() {
        let store = new_store();
        let root = store.create_group("root", "~", None, None).unwrap();
        let mid = store.create_group("mid", "~", Some(&root.id), None).unwrap();
        let leaf = store.create_group("leaf", "~", Some(&mid.id), None).unwrap();
        store.create_session("s1", &mid.id, "a", "/bin/sh", "~").unwrap();
        store.create_session("s2", &leaf.id, "b", "/bin/sh", "~").unwrap();

        // Delete mid -- should cascade to leaf and both sessions
        let deleted = store.delete_group(&mid.id).unwrap();
        assert_eq!(deleted.len(), 2);
        assert!(deleted.contains(&mid.id));
        assert!(deleted.contains(&leaf.id));

        // Root should survive
        assert!(store.get_group(&root.id).unwrap().is_some());
        assert!(store.list_sessions().unwrap().is_empty());
    }
}
