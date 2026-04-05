use crate::attention::SessionAttentionState;
use crate::pty::session::ToolState;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use uuid::Uuid;

pub struct Store {
    conn: Mutex<Connection>,
}

const SHARED_REMOTE_MODEL_VERSION_KEY: &str = "shared_remote_model_version";
const SHARED_REMOTE_MODEL_VERSION: &str = "1";

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
    #[serde(default)]
    pub sort_order: i32,
    pub is_alive: bool,
    /// Transient: detected foreground process (e.g. "claude", "codex")
    #[serde(default)]
    pub foreground_process: Option<String>,
    /// Transient: detected coding-agent state for the foreground process.
    #[serde(default)]
    pub tool_state: Option<ToolState>,
    /// Persisted on the remote server: which local group this session belongs to.
    /// Set when a session is created via create_remote_session and kept in sync
    /// when the user moves the session between groups. Used during sync to restore
    /// sessions to their correct local group, overriding any poisoned registry entry.
    #[serde(default)]
    pub local_group_id: Option<String>,
    #[serde(default)]
    pub attention_seq: i64,
    #[serde(default)]
    pub needs_attention: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attention_updated_at: Option<String>,
}

impl Store {
    pub fn new(path: &str) -> anyhow::Result<Self> {
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;",
        )?;
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
                is_alive    INTEGER NOT NULL DEFAULT 1,
                attention_seq INTEGER NOT NULL DEFAULT 0,
                attention_ack_seq INTEGER NOT NULL DEFAULT 0,
                attention_updated_at TEXT
            );
            CREATE TABLE IF NOT EXISTS settings (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_sessions_group_id ON sessions(group_id);
            CREATE TABLE IF NOT EXISTS session_group_registry (
                session_id TEXT PRIMARY KEY,
                group_id   TEXT NOT NULL
            );
            INSERT OR IGNORE INTO session_group_registry (session_id, group_id)
            SELECT id, group_id FROM sessions;",
        )?;
        // Migration: add parent_id column if it doesn't exist (for existing DBs)
        conn.execute_batch("ALTER TABLE groups ADD COLUMN parent_id TEXT REFERENCES groups(id);")
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
        conn.execute_batch("ALTER TABLE groups ADD COLUMN ssh_host TEXT;")
            .ok();
        // Migration: add local_group_id to sessions (for remote group assignment persistence)
        conn.execute_batch("ALTER TABLE sessions ADD COLUMN local_group_id TEXT;")
            .ok();
        conn.execute_batch(
            "ALTER TABLE sessions ADD COLUMN attention_seq INTEGER NOT NULL DEFAULT 0;",
        )
        .ok();
        conn.execute_batch(
            "ALTER TABLE sessions ADD COLUMN attention_ack_seq INTEGER NOT NULL DEFAULT 0;",
        )
        .ok();
        conn.execute_batch("ALTER TABLE sessions ADD COLUMN attention_updated_at TEXT;")
            .ok();
        Ok(())
    }

    #[allow(dead_code)]
    pub fn mark_shared_remote_model_initialized(&self) -> anyhow::Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?1, ?2)",
            params![SHARED_REMOTE_MODEL_VERSION_KEY, SHARED_REMOTE_MODEL_VERSION],
        )?;
        Ok(())
    }

    /// One-time upgrade step for the old SSH-local-mapping model.
    /// We intentionally discard stale SSH-backed local mirrors and let the
    /// remote-authoritative sync rebuild them in the shared format.
    pub fn migrate_legacy_shared_remote_model_if_needed(&self) -> anyhow::Result<bool> {
        let mut conn = self.conn.lock().unwrap();
        let current: Option<String> = conn
            .query_row(
                "SELECT value FROM settings WHERE key = ?1",
                params![SHARED_REMOTE_MODEL_VERSION_KEY],
                |row| row.get(0),
            )
            .optional()?;
        if current.as_deref() == Some(SHARED_REMOTE_MODEL_VERSION) {
            return Ok(false);
        }

        let tx = conn.transaction()?;
        tx.execute(
            "DELETE FROM session_group_registry
             WHERE session_id IN (
                 SELECT s.id FROM sessions s
                 JOIN groups g ON s.group_id = g.id
                 WHERE g.ssh_host IS NOT NULL
             )",
            [],
        )?;
        tx.execute(
            "DELETE FROM sessions
             WHERE group_id IN (SELECT id FROM groups WHERE ssh_host IS NOT NULL)",
            [],
        )?;
        tx.execute("DELETE FROM groups WHERE ssh_host IS NOT NULL", [])?;
        tx.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?1, ?2)",
            params![SHARED_REMOTE_MODEL_VERSION_KEY, SHARED_REMOTE_MODEL_VERSION],
        )?;
        tx.commit()?;
        Ok(true)
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
            .query_row(
                "SELECT COALESCE(MAX(sort_order), -1) FROM groups",
                [],
                |r| r.get(0),
            )
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

        let sql = format!("UPDATE groups SET {} WHERE id = ?", sets.join(", "));
        let conn = self.conn.lock().unwrap();
        let n = conn.execute(
            &sql,
            rusqlite::params_from_iter(values.iter().map(|v| v.as_ref())),
        )?;
        if n == 0 {
            anyhow::bail!("not_found");
        }
        Ok(())
    }

    pub fn upsert_remote_group_mirror(
        &self,
        group: &GroupRow,
        ssh_host: &str,
    ) -> anyhow::Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO groups (id, name, default_cwd, sort_order, parent_id, ssh_host, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(id) DO UPDATE SET
                 name = excluded.name,
                 default_cwd = excluded.default_cwd,
                 sort_order = excluded.sort_order,
                 parent_id = excluded.parent_id,
                 ssh_host = excluded.ssh_host,
                 created_at = excluded.created_at,
                 updated_at = excluded.updated_at",
            params![
                group.id.as_str(),
                group.name.as_str(),
                group.default_cwd.as_str(),
                group.sort_order,
                group.parent_id.as_deref(),
                ssh_host,
                group.created_at.as_str(),
                group.updated_at.as_str()
            ],
        )?;
        Ok(())
    }

    /// Collect all descendant group IDs (recursive) including the given id itself
    pub fn collect_descendant_ids(&self, id: &str) -> anyhow::Result<Vec<String>> {
        let conn = self.conn.lock().unwrap();
        let mut result = vec![id.to_string()];
        let mut queue = vec![id.to_string()];
        while let Some(parent) = queue.pop() {
            let mut stmt = conn.prepare("SELECT id FROM groups WHERE parent_id = ?1")?;
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
            tx.execute(
                "DELETE FROM session_group_registry WHERE session_id IN (SELECT id FROM sessions WHERE group_id = ?1)",
                params![gid],
            )?;
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

    /// Return the `ssh_host` field of a group directly (avoids constructing a full GroupRow).
    #[allow(dead_code)]
    pub fn get_group_ssh_host(&self, group_id: &str) -> anyhow::Result<Option<String>> {
        let conn = self.conn.lock().unwrap();
        let result = conn.query_row(
            "SELECT ssh_host FROM groups WHERE id = ?1",
            params![group_id],
            |row| row.get::<_, Option<String>>(0),
        );
        match result {
            Ok(v) => Ok(v),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    // --- Sessions ---

    pub fn list_sessions(&self) -> anyhow::Result<Vec<SessionRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, group_id, name, shell, cols, rows, cwd, created_at, last_active, sort_order, is_alive, local_group_id, attention_seq, attention_ack_seq, attention_updated_at FROM sessions ORDER BY sort_order, created_at",
        )?;
        let rows = stmt
            .query_map([], |row| {
                let attention_seq: i64 = row.get(12)?;
                let attention_ack_seq: i64 = row.get(13)?;
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
                    sort_order: row.get(9)?,
                    is_alive: row.get::<_, i32>(10)? != 0,
                    foreground_process: None,
                    tool_state: None,
                    local_group_id: row.get(11)?,
                    attention_seq,
                    needs_attention: attention_seq > attention_ack_seq,
                    attention_updated_at: row.get(14)?,
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
        local_group_id: Option<&str>,
    ) -> anyhow::Result<SessionRow> {
        let mut conn = self.conn.lock().unwrap();
        let now = chrono::Utc::now().to_rfc3339();
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO sessions (id, group_id, name, shell, cols, rows, cwd, created_at, last_active, sort_order, is_alive, local_group_id, attention_seq, attention_ack_seq, attention_updated_at) VALUES (?1, ?2, ?3, ?4, 80, 24, ?5, ?6, ?7, 0, 1, ?8, 0, 0, NULL)",
            params![id, group_id, name, shell, cwd, now, now, local_group_id],
        )?;
        tx.execute(
            "INSERT OR REPLACE INTO session_group_registry (session_id, group_id) VALUES (?1, ?2)",
            params![id, group_id],
        )?;
        tx.commit()?;
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
            sort_order: 0,
            is_alive: true,
            foreground_process: None,
            tool_state: None,
            local_group_id: local_group_id.map(|s| s.to_string()),
            attention_seq: 0,
            needs_attention: false,
            attention_updated_at: None,
        })
    }

    pub fn get_session(&self, id: &str) -> anyhow::Result<Option<SessionRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, group_id, name, shell, cols, rows, cwd, created_at, last_active, sort_order, is_alive, local_group_id, attention_seq, attention_ack_seq, attention_updated_at \
             FROM sessions WHERE id = ?1",
        )?;
        let row = stmt
            .query_row(params![id], |row| {
                let attention_seq: i64 = row.get(12)?;
                let attention_ack_seq: i64 = row.get(13)?;
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
                    sort_order: row.get(9)?,
                    is_alive: row.get::<_, i32>(10)? != 0,
                    foreground_process: None,
                    tool_state: None,
                    local_group_id: row.get(11)?,
                    attention_seq,
                    needs_attention: attention_seq > attention_ack_seq,
                    attention_updated_at: row.get(14)?,
                })
            })
            .ok();
        Ok(row)
    }

    pub fn get_session_attention(&self, id: &str) -> anyhow::Result<Option<SessionAttentionState>> {
        let conn = self.conn.lock().unwrap();
        let row = conn
            .query_row(
                "SELECT attention_seq, attention_ack_seq, attention_updated_at FROM sessions WHERE id = ?1",
                params![id],
                |row| {
                    let attention_seq: i64 = row.get(0)?;
                    let attention_ack_seq: i64 = row.get(1)?;
                    let attention_updated_at: Option<String> = row.get(2)?;
                    Ok(SessionAttentionState {
                        needs_attention: attention_seq > attention_ack_seq,
                        attention_seq,
                        attention_updated_at,
                    })
                },
            )
            .optional()?;
        Ok(row)
    }

    pub fn increment_session_attention(
        &self,
        id: &str,
        attention_updated_at: &str,
    ) -> anyhow::Result<Option<SessionAttentionState>> {
        let conn = self.conn.lock().unwrap();
        let updated = conn.execute(
            "UPDATE sessions
             SET attention_seq = attention_seq + 1,
                 attention_updated_at = ?1
             WHERE id = ?2",
            params![attention_updated_at, id],
        )?;
        if updated == 0 {
            return Ok(None);
        }
        let row = conn.query_row(
            "SELECT attention_seq, attention_ack_seq, attention_updated_at FROM sessions WHERE id = ?1",
            params![id],
            |row| {
                let attention_seq: i64 = row.get(0)?;
                let attention_ack_seq: i64 = row.get(1)?;
                let attention_updated_at: Option<String> = row.get(2)?;
                Ok(SessionAttentionState {
                    needs_attention: attention_seq > attention_ack_seq,
                    attention_seq,
                    attention_updated_at,
                })
            },
        )?;
        Ok(Some(row))
    }

    pub fn ack_session_attention(
        &self,
        id: &str,
        attention_seq: i64,
    ) -> anyhow::Result<Option<SessionAttentionState>> {
        let conn = self.conn.lock().unwrap();
        let current = conn
            .query_row(
                "SELECT attention_seq, attention_ack_seq FROM sessions WHERE id = ?1",
                params![id],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
            )
            .optional()?;
        let Some((current_seq, current_ack_seq)) = current else {
            return Ok(None);
        };
        let next_ack_seq =
            std::cmp::max(current_ack_seq, std::cmp::min(attention_seq, current_seq));
        conn.execute(
            "UPDATE sessions SET attention_ack_seq = ?1 WHERE id = ?2",
            params![next_ack_seq, id],
        )?;
        let row = conn.query_row(
            "SELECT attention_seq, attention_ack_seq, attention_updated_at FROM sessions WHERE id = ?1",
            params![id],
            |row| {
                let attention_seq: i64 = row.get(0)?;
                let attention_ack_seq: i64 = row.get(1)?;
                let attention_updated_at: Option<String> = row.get(2)?;
                Ok(SessionAttentionState {
                    needs_attention: attention_seq > attention_ack_seq,
                    attention_seq,
                    attention_updated_at,
                })
            },
        )?;
        Ok(Some(row))
    }

    pub fn upsert_remote_session_mirror(&self, session: &SessionRow) -> anyhow::Result<()> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO sessions (id, group_id, name, shell, cols, rows, cwd, created_at, last_active, sort_order, is_alive, local_group_id, attention_seq, attention_ack_seq, attention_updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, 0, 0, NULL)
             ON CONFLICT(id) DO UPDATE SET
                 group_id = excluded.group_id,
                 name = excluded.name,
                 shell = excluded.shell,
                 cols = excluded.cols,
                 rows = excluded.rows,
                 cwd = excluded.cwd,
                 created_at = excluded.created_at,
                 last_active = excluded.last_active,
                 sort_order = excluded.sort_order,
                 is_alive = excluded.is_alive,
                 local_group_id = excluded.local_group_id",
            params![
                session.id.as_str(),
                session.group_id.as_str(),
                session.name.as_str(),
                session.shell.as_str(),
                session.cols,
                session.rows,
                session.cwd.as_str(),
                session.created_at.as_str(),
                session.last_active.as_str(),
                session.sort_order,
                session.is_alive as i32,
                session.local_group_id.as_deref()
            ],
        )?;
        tx.execute(
            "INSERT OR REPLACE INTO session_group_registry (session_id, group_id) VALUES (?1, ?2)",
            params![session.id.as_str(), session.group_id.as_str()],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Returns the number of rows updated (0 means the session was not found).
    pub fn update_session_name(&self, id: &str, name: &str) -> anyhow::Result<usize> {
        let conn = self.conn.lock().unwrap();
        let n = conn.execute(
            "UPDATE sessions SET name = ?1 WHERE id = ?2",
            params![name, id],
        )?;
        Ok(n)
    }

    /// Returns the number of rows updated (0 means the session was not found).
    pub fn update_session_sort_order(&self, id: &str, sort_order: i32) -> anyhow::Result<usize> {
        let conn = self.conn.lock().unwrap();
        let n = conn.execute(
            "UPDATE sessions SET sort_order = ?1 WHERE id = ?2",
            params![sort_order, id],
        )?;
        Ok(n)
    }

    /// Returns the number of rows updated (0 means the session was not found).
    pub fn update_session_group(&self, id: &str, group_id: &str) -> anyhow::Result<usize> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let n = tx.execute(
            "UPDATE sessions SET group_id = ?1 WHERE id = ?2",
            params![group_id, id],
        )?;
        if n > 0 {
            tx.execute(
                "INSERT OR REPLACE INTO session_group_registry (session_id, group_id) VALUES (?1, ?2)",
                params![id, group_id],
            )?;
        }
        tx.commit()?;
        Ok(n)
    }

    /// Update the `local_group_id` field on a session. Used when the remote server
    /// receives a proxied PATCH from the local server after the user moves a session.
    #[allow(dead_code)]
    pub fn update_session_local_group_id(
        &self,
        id: &str,
        local_group_id: &str,
    ) -> anyhow::Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE sessions SET local_group_id = ?1 WHERE id = ?2",
            params![local_group_id, id],
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

    /// Permanently delete a session and its registry entry.
    ///
    /// The registry entry is intentionally cleared here because this is an explicit
    /// user-initiated deletion (HTTP DELETE), which also proxies the delete to the
    /// remote server.  If the session ever reappears via sync it is treated as a new
    /// first-time session and falls back to `fallback_group_id`.
    ///
    /// Contrast with `delete_remote_sessions`, which is called on server *restart* and
    /// intentionally leaves the registry intact so SSH sessions are restored to their
    /// original groups on reconnect.
    pub fn delete_session(&self, id: &str) -> anyhow::Result<()> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM sessions WHERE id = ?1", params![id])?;
        tx.execute(
            "DELETE FROM session_group_registry WHERE session_id = ?1",
            params![id],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Return the `ssh_host` of the group that owns this session, if any.
    /// Returns `None` when the session is local (group has no ssh_host).
    pub fn get_session_ssh_host(&self, session_id: &str) -> anyhow::Result<Option<String>> {
        let conn = self.conn.lock().unwrap();
        let result = conn.query_row(
            "SELECT g.ssh_host FROM sessions s \
             JOIN groups g ON s.group_id = g.id \
             WHERE s.id = ?1",
            params![session_id],
            |row| row.get::<_, Option<String>>(0),
        );
        match result {
            Ok(v) => Ok(v),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// Mark all sessions belonging to local (non-SSH) groups as dead.
    /// Called on startup: PTYs don't survive a restart, but we keep the records
    /// so the user can still see their session list and scrollback history.
    /// Does NOT touch `session_group_registry`.
    pub fn mark_local_sessions_dead(&self) -> anyhow::Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE sessions SET is_alive = 0 \
             WHERE group_id IN (SELECT id FROM groups WHERE ssh_host IS NULL)",
            [],
        )?;
        Ok(())
    }

    /// Return the IDs of all sessions belonging to SSH-backed groups.
    #[allow(dead_code)]
    pub fn get_remote_session_ids(&self) -> anyhow::Result<Vec<String>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT s.id FROM sessions s \
             JOIN groups g ON s.group_id = g.id WHERE g.ssh_host IS NOT NULL",
        )?;
        let ids = stmt
            .query_map([], |row| row.get(0))?
            .collect::<Result<Vec<String>, _>>()?;
        Ok(ids)
    }

    pub fn get_remote_session_ids_by_host(&self, host_alias: &str) -> anyhow::Result<Vec<String>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT s.id FROM sessions s \
             JOIN groups g ON s.group_id = g.id WHERE g.ssh_host = ?1",
        )?;
        let ids = stmt
            .query_map(params![host_alias], |row| row.get(0))?
            .collect::<Result<Vec<String>, _>>()?;
        Ok(ids)
    }

    /// Delete all sessions belonging to SSH-backed groups.
    /// Called on startup; these sessions are re-imported by the sync mechanism when
    /// SSH tunnels reconnect. Intentionally does NOT touch `session_group_registry` —
    /// that table persists group assignments so sessions are restored to the right group.
    #[allow(dead_code)]
    pub fn delete_remote_sessions(&self) -> anyhow::Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "DELETE FROM sessions \
             WHERE group_id IN (SELECT id FROM groups WHERE ssh_host IS NOT NULL)",
            [],
        )?;
        Ok(())
    }

    /// Return all sessions belonging to any of the given group IDs.
    pub fn get_sessions_in_groups(&self, group_ids: &[String]) -> anyhow::Result<Vec<SessionRow>> {
        if group_ids.is_empty() {
            return Ok(Vec::new());
        }
        let conn = self.conn.lock().unwrap();
        let placeholders = group_ids
            .iter()
            .enumerate()
            .map(|(i, _)| format!("?{}", i + 1))
            .collect::<Vec<_>>()
            .join(", ");
        let sql = format!(
            "SELECT id, group_id, name, shell, cols, rows, cwd, created_at, last_active, \
             sort_order, is_alive, local_group_id, attention_seq, attention_ack_seq, attention_updated_at \
             FROM sessions WHERE group_id IN ({})",
            placeholders
        );
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt
            .query_map(rusqlite::params_from_iter(group_ids.iter()), |row| {
                let attention_seq: i64 = row.get(12)?;
                let attention_ack_seq: i64 = row.get(13)?;
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
                    sort_order: row.get(9)?,
                    is_alive: row.get::<_, i32>(10)? != 0,
                    foreground_process: None,
                    tool_state: None,
                    local_group_id: row.get(11)?,
                    attention_seq,
                    needs_attention: attention_seq > attention_ack_seq,
                    attention_updated_at: row.get(14)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
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

    pub fn prune_remote_session_mirrors(
        &self,
        host_alias: &str,
        keep_ids: &[String],
    ) -> anyhow::Result<()> {
        let keep: std::collections::HashSet<&str> = keep_ids.iter().map(String::as_str).collect();
        let stale_ids = self
            .get_remote_session_ids_by_host(host_alias)?
            .into_iter()
            .filter(|id| !keep.contains(id.as_str()))
            .collect::<Vec<_>>();
        for id in stale_ids {
            self.delete_session(&id)?;
        }
        Ok(())
    }

    pub fn batch_reorder_sessions(
        &self,
        orders: &[(String, i32, Option<String>)],
    ) -> anyhow::Result<()> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        for (id, order, group_id) in orders {
            tx.execute(
                "UPDATE sessions SET sort_order = ?1 WHERE id = ?2",
                params![order, id],
            )?;
            if let Some(gid) = group_id {
                tx.execute(
                    "UPDATE sessions SET group_id = ?1 WHERE id = ?2",
                    params![gid, id],
                )?;
                tx.execute(
                    "INSERT OR REPLACE INTO session_group_registry (session_id, group_id) VALUES (?1, ?2)",
                    params![id, gid],
                )?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn get_groups_by_ssh_host(&self, host_alias: &str) -> anyhow::Result<Vec<GroupRow>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT id, name, default_cwd, sort_order, parent_id, created_at, updated_at, ssh_host \
             FROM groups WHERE ssh_host = ?1 ORDER BY sort_order, name",
        )?;
        let rows = stmt
            .query_map(params![host_alias], |row| {
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

    pub fn prune_remote_group_mirrors(
        &self,
        host_alias: &str,
        keep_ids: &[String],
    ) -> anyhow::Result<()> {
        let keep: std::collections::HashSet<&str> = keep_ids.iter().map(String::as_str).collect();
        let groups = self.get_groups_by_ssh_host(host_alias)?;
        let stale: std::collections::HashSet<String> = groups
            .iter()
            .filter(|group| !keep.contains(group.id.as_str()))
            .map(|group| group.id.clone())
            .collect();

        let stale_roots = groups
            .into_iter()
            .filter(|group| {
                stale.contains(&group.id)
                    && group
                        .parent_id
                        .as_deref()
                        .map(|parent| !stale.contains(parent))
                        .unwrap_or(true)
            })
            .map(|group| group.id)
            .collect::<Vec<_>>();

        for id in stale_roots {
            self.delete_group(&id)?;
        }
        Ok(())
    }

    /// Insert a session record if no record with the same id already exists.
    /// Returns true if a row was inserted, false if it already existed.
    ///
    /// Group assignment priority:
    /// 1. `local_group_id` (from remote session field) — authoritative; also repairs
    ///    any poisoned registry entry via INSERT OR REPLACE.
    /// 2. `session_group_registry` — used when `local_group_id` is absent (old sessions).
    /// 3. `fallback_group_id` — last resort; does NOT write to registry (avoids poisoning).
    #[allow(dead_code)]
    pub fn try_insert_remote_session(
        &self,
        id: &str,
        fallback_group_id: &str,
        local_group_id: Option<&str>,
        name: &str,
        shell: &str,
        cwd: &str,
        is_alive: bool,
    ) -> anyhow::Result<bool> {
        let mut conn = self.conn.lock().unwrap();

        let group_id: String;
        let authoritative: bool;

        if let Some(lgid) = local_group_id {
            // Authoritative source: the remote server remembers which local group this belongs to.
            // Validate the group still exists locally before using it; if it was deleted while
            // the tunnel was down, fall back to the registry/fallback path.
            let exists = conn
                .query_row("SELECT 1 FROM groups WHERE id = ?1", params![lgid], |_| {
                    Ok(())
                })
                .is_ok();
            if exists {
                group_id = lgid.to_string();
                authoritative = true;
            } else {
                group_id = conn
                    .query_row(
                        "SELECT group_id FROM session_group_registry WHERE session_id = ?1",
                        params![id],
                        |row| row.get(0),
                    )
                    .unwrap_or_else(|_| fallback_group_id.to_string());
                authoritative = false;
            }
        } else {
            // Fall back to registry, then to the caller-supplied fallback.
            group_id = conn
                .query_row(
                    "SELECT group_id FROM session_group_registry WHERE session_id = ?1",
                    params![id],
                    |row| row.get(0),
                )
                .unwrap_or_else(|_| fallback_group_id.to_string());
            authoritative = false;
        }

        let now = chrono::Utc::now().to_rfc3339();
        let tx = conn.transaction()?;

        if authoritative {
            // Fix any poisoned registry entry with the correct authoritative value.
            tx.execute(
                "INSERT OR REPLACE INTO session_group_registry (session_id, group_id) VALUES (?1, ?2)",
                params![id, group_id],
            )?;
        }

        let n = tx.execute(
            "INSERT OR IGNORE INTO sessions \
             (id, group_id, name, shell, cols, rows, cwd, created_at, last_active, sort_order, is_alive, local_group_id) \
             VALUES (?1, ?2, ?3, ?4, 80, 24, ?5, ?6, ?7, 0, ?8, ?9)",
            params![id, group_id, name, shell, cwd, now, now, is_alive as i32, local_group_id],
        )?;
        tx.commit()?;
        Ok(n > 0)
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
        store
            .update_group(&group.id, Some("new"), None, None, None)
            .unwrap();
        let fetched = store.get_group(&group.id).unwrap().unwrap();
        assert_eq!(fetched.name, "new");
    }

    #[test]
    fn update_group_cwd() {
        let store = new_store();
        let group = store.create_group("g", "/old", None, None).unwrap();
        store
            .update_group(&group.id, None, Some("/new"), None, None)
            .unwrap();
        let fetched = store.get_group(&group.id).unwrap().unwrap();
        assert_eq!(fetched.default_cwd, "/new");
    }

    #[test]
    fn update_group_sort_order() {
        let store = new_store();
        let group = store.create_group("g", "~", None, None).unwrap();
        store
            .update_group(&group.id, None, None, Some(99), None)
            .unwrap();
        let fetched = store.get_group(&group.id).unwrap().unwrap();
        assert_eq!(fetched.sort_order, 99);
    }

    #[test]
    fn update_group_noop_with_no_fields() {
        let store = new_store();
        let group = store.create_group("g", "~", None, None).unwrap();
        // Should succeed even with nothing to update
        store
            .update_group(&group.id, None, None, None, None)
            .unwrap();
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
        let child = store
            .create_group("child", "~", Some(&parent.id), None)
            .unwrap();
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
        let grandchild = store
            .create_group("gc", "~", Some(&child1.id), None)
            .unwrap();

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
        let child = store
            .create_group("child", "~", Some(&root.id), None)
            .unwrap();
        // Collecting from child should only return child itself
        let ids = store.collect_descendant_ids(&child.id).unwrap();
        assert_eq!(ids, vec![child.id]);
    }

    // --- Recursive Deletion ---

    #[test]
    fn delete_group_cascades_to_children() {
        let store = new_store();
        let root = store.create_group("root", "~", None, None).unwrap();
        let child = store
            .create_group("child", "~", Some(&root.id), None)
            .unwrap();
        let grandchild = store
            .create_group("grandchild", "~", Some(&child.id), None)
            .unwrap();

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
        store
            .create_session("s1", &group.id, "session1", "/bin/sh", "~", None)
            .unwrap();
        store
            .create_session("s2", &group.id, "session2", "/bin/sh", "~", None)
            .unwrap();

        store.delete_group(&group.id).unwrap();
        let sessions = store.list_sessions().unwrap();
        assert!(sessions.is_empty());
    }

    #[test]
    fn delete_group_clears_registry() {
        // After the group is deleted, the session's registry entry must be gone so
        // try_insert_remote_session uses the fallback group instead of the stale one.
        let store = new_store();
        let g_original = store
            .create_group("original", "~", None, Some("host"))
            .unwrap();
        let g_fallback = store
            .create_group("fallback", "~", None, Some("host"))
            .unwrap();

        store
            .create_session("s1", &g_original.id, "s", "/bin/sh", "~", None)
            .unwrap();
        store.delete_group(&g_original.id).unwrap();

        // g_original is gone; inserting via sync should use fallback, not the deleted group.
        store
            .try_insert_remote_session("s1", &g_fallback.id, None, "s", "/bin/sh", "~", true)
            .unwrap();
        let sessions = store.list_sessions().unwrap();
        assert_eq!(
            sessions[0].group_id, g_fallback.id,
            "deleted group's registry entry must be cleared so fallback is used"
        );
    }

    #[test]
    fn delete_group_cascades_nested_sessions() {
        let store = new_store();
        let root = store.create_group("root", "~", None, None).unwrap();
        let child = store
            .create_group("child", "~", Some(&root.id), None)
            .unwrap();
        store
            .create_session("s1", &root.id, "s1", "/bin/sh", "~", None)
            .unwrap();
        store
            .create_session("s2", &child.id, "s2", "/bin/sh", "~", None)
            .unwrap();

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
        let child = store
            .create_group("child", "~", Some(&parent.id), None)
            .unwrap();
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

        store
            .batch_reorder_groups(&[(g3.id.clone(), 0), (g1.id.clone(), 1), (g2.id.clone(), 2)])
            .unwrap();

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
        let session = store
            .create_session("sid1", &group.id, "my-session", "/bin/bash", "/home", None)
            .unwrap();
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
        store
            .create_session("s1", &group.id, "old", "/bin/sh", "~", None)
            .unwrap();
        store.update_session_name("s1", "new").unwrap();
        let sessions = store.list_sessions().unwrap();
        assert_eq!(sessions[0].name, "new");
    }

    #[test]
    fn update_session_sort_order() {
        let store = new_store();
        let group = store.create_group("g", "~", None, None).unwrap();
        store
            .create_session("s1", &group.id, "s", "/bin/sh", "~", None)
            .unwrap();
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
        store
            .create_session("s1", &g1.id, "s", "/bin/sh", "~", None)
            .unwrap();
        store.update_session_group("s1", &g2.id).unwrap();
        let sessions = store.list_sessions().unwrap();
        assert_eq!(sessions[0].group_id, g2.id);
    }

    #[test]
    fn update_session_group_updates_registry() {
        // After move g1→g2, restart, re-sync with g3 as fallback → session must land in g2.
        let store = new_store();
        let g1 = store.create_group("g1", "~", None, Some("host")).unwrap();
        let g2 = store.create_group("g2", "~", None, Some("host")).unwrap();
        let g3 = store.create_group("g3", "~", None, Some("host")).unwrap();

        store
            .create_session("s1", &g1.id, "s", "/bin/sh", "~", None)
            .unwrap();
        store.update_session_group("s1", &g2.id).unwrap();

        // Simulate restart: remote sessions are deleted but registry is preserved
        store.delete_remote_sessions().unwrap();

        store
            .try_insert_remote_session("s1", &g3.id, None, "s", "/bin/sh", "~", true)
            .unwrap();
        let sessions = store.list_sessions().unwrap();
        assert_eq!(
            sessions[0].group_id, g2.id,
            "registry must reflect the post-move group, not the fallback"
        );
    }

    #[test]
    fn delete_session() {
        let store = new_store();
        let group = store.create_group("g", "~", None, None).unwrap();
        store
            .create_session("s1", &group.id, "s", "/bin/sh", "~", None)
            .unwrap();
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
    fn delete_session_clears_registry() {
        // Documents that explicit deletion (user-initiated) also clears the registry entry.
        // If the session reappears via sync, it falls back to fallback_group_id.
        let store = new_store();
        let g_original = store
            .create_group("original", "~", None, Some("host"))
            .unwrap();
        let g_fallback = store
            .create_group("fallback", "~", None, Some("host"))
            .unwrap();

        store
            .create_session("s1", &g_original.id, "s", "/bin/sh", "~", None)
            .unwrap();
        store.delete_session("s1").unwrap();

        store
            .try_insert_remote_session("s1", &g_fallback.id, None, "s", "/bin/sh", "~", true)
            .unwrap();
        let sessions = store.list_sessions().unwrap();
        assert_eq!(
            sessions[0].group_id, g_fallback.id,
            "after explicit deletion, registry is cleared and fallback is used on re-sync"
        );
    }

    #[test]
    fn mark_local_sessions_dead_and_delete_remote_sessions() {
        let store = new_store();
        let local_group = store.create_group("local", "~", None, None).unwrap();
        let remote_group = store
            .create_group("remote", "~", None, Some("myhost"))
            .unwrap();
        store
            .create_session("s-local", &local_group.id, "a", "/bin/sh", "~", None)
            .unwrap();
        store
            .create_session("s-remote", &remote_group.id, "b", "/bin/sh", "~", None)
            .unwrap();

        // Simulate restart
        store.mark_local_sessions_dead().unwrap();
        store.delete_remote_sessions().unwrap();

        let sessions = store.list_sessions().unwrap();
        // Remote session is gone; local session is kept but marked dead
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, "s-local");
        assert!(
            !sessions[0].is_alive,
            "local session must be marked dead after restart"
        );
    }

    #[test]
    fn mark_local_sessions_dead_when_empty() {
        let store = new_store();
        store.mark_local_sessions_dead().unwrap();
        store.delete_remote_sessions().unwrap();
    }

    #[test]
    fn delete_remote_sessions_preserves_registry() {
        // Verifies that the registry survives delete_remote_sessions (server restart simulation).
        let store = new_store();
        let g_original = store
            .create_group("original", "~", None, Some("myhost"))
            .unwrap();
        let g_wrong = store
            .create_group("wrong", "~", None, Some("myhost"))
            .unwrap();

        store
            .create_session("s1", &g_original.id, "sess", "/bin/sh", "~", None)
            .unwrap();
        store.delete_remote_sessions().unwrap();
        assert!(store.list_sessions().unwrap().is_empty());

        // Registry must survive: wrong fallback must not win
        store
            .try_insert_remote_session("s1", &g_wrong.id, None, "sess", "/bin/sh", "~", true)
            .unwrap();
        let sessions = store.list_sessions().unwrap();
        assert_eq!(
            sessions[0].group_id, g_original.id,
            "delete_remote_sessions must not clear session_group_registry"
        );
    }

    // --- Batch Reorder Sessions ---

    #[test]
    fn batch_reorder_sessions_basic() {
        let store = new_store();
        let group = store.create_group("g", "~", None, None).unwrap();
        store
            .create_session("s1", &group.id, "a", "/bin/sh", "~", None)
            .unwrap();
        store
            .create_session("s2", &group.id, "b", "/bin/sh", "~", None)
            .unwrap();
        store
            .create_session("s3", &group.id, "c", "/bin/sh", "~", None)
            .unwrap();

        store
            .batch_reorder_sessions(&[
                ("s3".to_string(), 0, None),
                ("s1".to_string(), 1, None),
                ("s2".to_string(), 2, None),
            ])
            .unwrap();

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
        store
            .create_session("s1", &group.id, "s", "/bin/sh", "~", None)
            .unwrap();
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
        store
            .create_session("s1", &g1.id, "a", "/bin/sh", "~", None)
            .unwrap();
        store
            .create_session("s2", &g2.id, "b", "/bin/sh", "~", None)
            .unwrap();

        store.delete_group(&g1.id).unwrap();

        let sessions = store.list_sessions().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, "s2");
    }

    #[test]
    fn delete_middle_of_tree() {
        let store = new_store();
        let root = store.create_group("root", "~", None, None).unwrap();
        let mid = store
            .create_group("mid", "~", Some(&root.id), None)
            .unwrap();
        let leaf = store
            .create_group("leaf", "~", Some(&mid.id), None)
            .unwrap();
        store
            .create_session("s1", &mid.id, "a", "/bin/sh", "~", None)
            .unwrap();
        store
            .create_session("s2", &leaf.id, "b", "/bin/sh", "~", None)
            .unwrap();

        // Delete mid -- should cascade to leaf and both sessions
        let deleted = store.delete_group(&mid.id).unwrap();
        assert_eq!(deleted.len(), 2);
        assert!(deleted.contains(&mid.id));
        assert!(deleted.contains(&leaf.id));

        // Root should survive
        assert!(store.get_group(&root.id).unwrap().is_some());
        assert!(store.list_sessions().unwrap().is_empty());
    }

    // --- Remote SSH helpers ---

    #[test]
    fn get_group_ssh_host_none_for_local_group() {
        let store = new_store();
        let g = store.create_group("local", "~", None, None).unwrap();
        let result = store.get_group_ssh_host(&g.id).unwrap();
        assert_eq!(result, None);
    }

    #[test]
    fn get_group_ssh_host_returns_value() {
        let store = new_store();
        let g = store
            .create_group("remote", "~", None, Some("user@host"))
            .unwrap();
        let result = store.get_group_ssh_host(&g.id).unwrap();
        assert_eq!(result, Some("user@host".to_string()));
    }

    #[test]
    fn get_group_ssh_host_nonexistent_group() {
        let store = new_store();
        let result = store.get_group_ssh_host("no-such-id").unwrap();
        assert_eq!(result, None);
    }

    #[test]
    fn get_session_ssh_host_none_for_local_session() {
        let store = new_store();
        let g = store.create_group("local", "~", None, None).unwrap();
        store
            .create_session("s1", &g.id, "sess", "/bin/sh", "~", None)
            .unwrap();
        let result = store.get_session_ssh_host("s1").unwrap();
        assert_eq!(result, None);
    }

    #[test]
    fn get_session_ssh_host_returns_value_for_ssh_group() {
        let store = new_store();
        let g = store
            .create_group("remote", "~", None, Some("myhost"))
            .unwrap();
        store
            .create_session("s2", &g.id, "sess", "ssh myhost", "~", None)
            .unwrap();
        let result = store.get_session_ssh_host("s2").unwrap();
        assert_eq!(result, Some("myhost".to_string()));
    }

    #[test]
    fn get_session_ssh_host_nonexistent_session() {
        let store = new_store();
        let result = store.get_session_ssh_host("no-such-session").unwrap();
        assert_eq!(result, None);
    }

    #[test]
    fn get_groups_by_ssh_host_empty() {
        let store = new_store();
        store.create_group("local", "~", None, None).unwrap();
        let result = store.get_groups_by_ssh_host("myhost").unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn get_groups_by_ssh_host_returns_matching() {
        let store = new_store();
        store.create_group("local", "~", None, None).unwrap();
        let g1 = store
            .create_group("remote1", "~", None, Some("myhost"))
            .unwrap();
        let g2 = store
            .create_group("remote2", "~", None, Some("myhost"))
            .unwrap();
        store
            .create_group("other", "~", None, Some("otherhost"))
            .unwrap();

        let result = store.get_groups_by_ssh_host("myhost").unwrap();
        assert_eq!(result.len(), 2);
        let ids: Vec<_> = result.iter().map(|g| g.id.as_str()).collect();
        assert!(ids.contains(&g1.id.as_str()));
        assert!(ids.contains(&g2.id.as_str()));
    }

    #[test]
    fn try_insert_remote_session_inserts_new() {
        let store = new_store();
        let g = store.create_group("g", "~", None, Some("myhost")).unwrap();
        let inserted = store
            .try_insert_remote_session("sid1", &g.id, None, "sess", "/bin/sh", "~", true)
            .unwrap();
        assert!(inserted);
        let sessions = store.list_sessions().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, "sid1");
    }

    #[test]
    fn try_insert_remote_session_respects_registry() {
        // Simulate: session was created in group A, server restarts, sync uses group B as fallback.
        // The registry should win and restore the session to group A.
        let store = new_store();
        let g_a = store
            .create_group("groupA", "~", None, Some("myhost"))
            .unwrap();
        let g_b = store
            .create_group("groupB", "~", None, Some("myhost"))
            .unwrap();

        // Create session in group A (populates registry)
        store
            .create_session("sid1", &g_a.id, "sess", "/bin/sh", "~", None)
            .unwrap();

        // Simulate restart: remote sessions deleted, registry survives
        store.delete_remote_sessions().unwrap();
        assert!(store.list_sessions().unwrap().is_empty());

        // Sync passes group B as fallback, but registry says group A
        let inserted = store
            .try_insert_remote_session("sid1", &g_b.id, None, "sess", "/bin/sh", "~", true)
            .unwrap();
        assert!(inserted);
        let sessions = store.list_sessions().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(
            sessions[0].group_id, g_a.id,
            "session should be restored to its original group A, not fallback group B"
        );
    }

    #[test]
    fn try_insert_remote_session_uses_local_group_id() {
        // Core regression test: local_group_id from remote overrides a poisoned registry entry.
        let store = new_store();
        let g_a = store
            .create_group("groupA", "~", None, Some("myhost"))
            .unwrap();
        let g_b = store
            .create_group("groupB", "~", None, Some("myhost"))
            .unwrap();
        let g_poison = store
            .create_group("poison", "~", None, Some("myhost"))
            .unwrap();

        // Simulate a poisoned registry (e.g. from a prior buggy sync).
        // Manually insert a wrong registry entry for the session.
        {
            let conn = store.conn.lock().unwrap();
            conn.execute(
                "INSERT INTO session_group_registry (session_id, group_id) VALUES ('sid-x', ?1)",
                rusqlite::params![g_poison.id],
            )
            .unwrap();
        }

        // Sync arrives with local_group_id = groupB (authoritative, set at creation time).
        // Despite the poisoned registry saying "poison", it should go to groupB.
        let inserted = store
            .try_insert_remote_session(
                "sid-x",
                &g_a.id,
                Some(&g_b.id),
                "sess",
                "/bin/sh",
                "~",
                true,
            )
            .unwrap();
        assert!(inserted);
        let sessions = store.list_sessions().unwrap();
        assert_eq!(
            sessions[0].group_id, g_b.id,
            "local_group_id from remote must override a poisoned registry entry"
        );
        assert_eq!(
            sessions[0].local_group_id,
            Some(g_b.id.clone()),
            "local_group_id must be persisted in the local session row"
        );

        // Registry should now be corrected to groupB.
        let reg_group: String = {
            let conn = store.conn.lock().unwrap();
            conn.query_row(
                "SELECT group_id FROM session_group_registry WHERE session_id = 'sid-x'",
                [],
                |r| r.get(0),
            )
            .unwrap()
        };
        assert_eq!(
            reg_group, g_b.id,
            "registry must be updated to the authoritative group"
        );
    }

    #[test]
    fn try_insert_remote_session_ignores_duplicate() {
        let store = new_store();
        let g = store.create_group("g", "~", None, Some("myhost")).unwrap();
        let first = store
            .try_insert_remote_session("sid1", &g.id, None, "sess", "/bin/sh", "~", true)
            .unwrap();
        assert!(first);
        let second = store
            .try_insert_remote_session("sid1", &g.id, None, "sess", "/bin/sh", "~", true)
            .unwrap();
        assert!(!second);
        // Still only one row
        assert_eq!(store.list_sessions().unwrap().len(), 1);
    }

    #[test]
    fn try_insert_remote_session_falls_back_when_local_group_id_group_deleted() {
        // If local_group_id refers to a group that has since been deleted, the insert
        // must fall back to the registry/fallback rather than failing or using a dangling FK.
        let store = new_store();
        let g_alive = store
            .create_group("alive", "~", None, Some("myhost"))
            .unwrap();
        let g_dead = store
            .create_group("dead", "~", None, Some("myhost"))
            .unwrap();

        // Delete the group that local_group_id will point to
        store.delete_group(&g_dead.id).unwrap();

        // Try inserting with local_group_id pointing to the now-deleted group
        let inserted = store
            .try_insert_remote_session(
                "sid-orphan",
                &g_alive.id,
                Some(&g_dead.id),
                "sess",
                "/bin/sh",
                "~",
                true,
            )
            .unwrap();
        assert!(
            inserted,
            "insert should succeed despite deleted local_group_id"
        );

        let sessions = store.list_sessions().unwrap();
        assert_eq!(sessions.len(), 1);
        // Must fall back to g_alive (registry or fallback), not the deleted g_dead
        assert_eq!(
            sessions[0].group_id, g_alive.id,
            "session must land in fallback group when local_group_id group is gone"
        );
    }
}
