//! SQLite persistence layer.
//!
//! All persistence concerns live here: projects and their configuration,
//! execution sessions, trace events, AST assignment records, experiments and
//! small key/value settings. The rest of the backend treats this module as a
//! plain repository API.

use crate::error::{AppError, AppResult};
use crate::models::*;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Row};
use std::path::Path;
use std::sync::{Mutex, MutexGuard};

const SESSION_COLUMNS: &str = "id, project_id, experiment_id, kind, label, command, args, stdin, cwd, \
     entry_file, python, status, exit_code, started_at, finished_at, duration_ms, \
     peak_memory_bytes, timeout_ms, error, substr(stdout, 1, 320), substr(stderr, 1, 320), \
     length(CAST(stdout AS BLOB)), length(CAST(stderr AS BLOB)), trace_events, trace_truncated";

const TRACE_COLUMNS: &str = "id, session_id, seq, ts, kind, frame, parent, depth, file, line, func, \
     name, value, vtype, changed";

/// Captured output is cut off at this many bytes while the run streams in.
const MAX_STORED_OUTPUT_BYTES: usize = 3_000_000;

pub struct Storage {
    conn: Mutex<Connection>,
}

impl Storage {
    pub fn open(path: &Path) -> AppResult<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(path)?;
        let storage = Self {
            conn: Mutex::new(conn),
        };
        {
            let guard = storage.lock()?;
            guard.execute_batch(
                "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;",
            )?;
            Self::migrate(&guard)?;
        }
        Ok(storage)
    }

    pub fn open_in_memory() -> AppResult<Self> {
        let conn = Connection::open_in_memory()?;
        let storage = Self {
            conn: Mutex::new(conn),
        };
        {
            let guard = storage.lock()?;
            guard.execute_batch("PRAGMA foreign_keys=ON;")?;
            Self::migrate(&guard)?;
        }
        Ok(storage)
    }

    fn lock(&self) -> AppResult<MutexGuard<'_, Connection>> {
        self.conn
            .lock()
            .map_err(|_| AppError::message("Storage lock was poisoned"))
    }

    fn migrate(conn: &Connection) -> AppResult<()> {
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                root_path TEXT NOT NULL UNIQUE,
                language TEXT NOT NULL,
                entry_point TEXT,
                run_args TEXT NOT NULL DEFAULT '[]',
                timeout_ms INTEGER NOT NULL DEFAULT 20000,
                tracing INTEGER NOT NULL DEFAULT 1,
                consent INTEGER NOT NULL DEFAULT 0,
                python_path TEXT,
                created_at INTEGER NOT NULL,
                last_opened_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                experiment_id TEXT,
                kind TEXT NOT NULL,
                label TEXT,
                command TEXT NOT NULL,
                args TEXT NOT NULL DEFAULT '[]',
                stdin TEXT,
                cwd TEXT NOT NULL,
                entry_file TEXT,
                python TEXT NOT NULL DEFAULT 'python3',
                status TEXT NOT NULL,
                exit_code INTEGER,
                started_at INTEGER NOT NULL,
                finished_at INTEGER,
                duration_ms INTEGER,
                peak_memory_bytes INTEGER,
                timeout_ms INTEGER NOT NULL DEFAULT 20000,
                error TEXT,
                stdout TEXT NOT NULL DEFAULT '',
                stderr TEXT NOT NULL DEFAULT '',
                trace_events INTEGER NOT NULL DEFAULT 0,
                trace_truncated INTEGER NOT NULL DEFAULT 0,
                trace_file TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project_id, started_at DESC);
            CREATE INDEX IF NOT EXISTS idx_sessions_experiment ON sessions(experiment_id);

            CREATE TABLE IF NOT EXISTS trace_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                seq INTEGER NOT NULL,
                ts INTEGER NOT NULL,
                kind TEXT NOT NULL,
                frame INTEGER,
                parent INTEGER,
                depth INTEGER,
                file TEXT,
                line INTEGER,
                func TEXT,
                name TEXT,
                value TEXT,
                vtype TEXT,
                changed INTEGER,
                payload TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_trace_session_seq ON trace_events(session_id, seq);
            CREATE INDEX IF NOT EXISTS idx_trace_session_kind ON trace_events(session_id, kind);
            CREATE INDEX IF NOT EXISTS idx_trace_name ON trace_events(session_id, name, seq);

            CREATE TABLE IF NOT EXISTS assignments (
                workspace_id TEXT NOT NULL,
                file TEXT NOT NULL,
                line INTEGER NOT NULL,
                col INTEGER NOT NULL DEFAULT 0,
                func TEXT NOT NULL,
                target TEXT NOT NULL,
                sources TEXT NOT NULL DEFAULT '[]',
                callee TEXT,
                kind TEXT NOT NULL,
                PRIMARY KEY (workspace_id, file, line, col, func, target)
            );
            CREATE INDEX IF NOT EXISTS idx_assignments_workspace ON assignments(workspace_id, file);

            CREATE TABLE IF NOT EXISTS experiments (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                baseline_session_id TEXT NOT NULL,
                name TEXT NOT NULL,
                note TEXT,
                path TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_experiments_project ON experiments(project_id, created_at DESC);

            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            "#,
        )?;
        Ok(())
    }

    // -- projects ----------------------------------------------------------

    pub fn upsert_project(&self, project: &Project) -> AppResult<()> {
        let args = serde_json::to_string(&project.run_args)?;
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO projects (id, name, root_path, language, entry_point, run_args, timeout_ms, \
             tracing, consent, python_path, created_at, last_opened_at) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12) \
             ON CONFLICT(root_path) DO UPDATE SET \
                name = excluded.name, \
                last_opened_at = excluded.last_opened_at, \
                language = excluded.language, \
                entry_point = COALESCE(projects.entry_point, excluded.entry_point)",
            params![
                project.id,
                project.name,
                project.root_path,
                project.language,
                project.entry_point,
                args,
                project.timeout_ms as i64,
                project.tracing as i64,
                project.consent_granted as i64,
                project.python_path,
                project.created_at,
                project.last_opened_at,
            ],
        )?;
        Ok(())
    }

    pub fn get_project(&self, id: &str) -> AppResult<Project> {
        let conn = self.lock()?;
        conn.query_row(
            "SELECT id, name, root_path, language, entry_point, run_args, timeout_ms, tracing, \
             consent, python_path, created_at, last_opened_at FROM projects WHERE id = ?1",
            params![id],
            map_project,
        )
        .optional()?
        .ok_or_else(|| AppError::not_found("Project not found"))
    }

    pub fn get_project_by_root(&self, root: &str) -> AppResult<Option<Project>> {
        let conn = self.lock()?;
        Ok(conn
            .query_row(
                "SELECT id, name, root_path, language, entry_point, run_args, timeout_ms, tracing, \
                 consent, python_path, created_at, last_opened_at FROM projects WHERE root_path = ?1",
                params![root],
                map_project,
            )
            .optional()?)
    }

    pub fn list_projects(&self, limit: u32) -> AppResult<Vec<Project>> {
        let conn = self.lock()?;
        let mut statement = conn.prepare(
            "SELECT id, name, root_path, language, entry_point, run_args, timeout_ms, tracing, \
             consent, python_path, created_at, last_opened_at FROM projects \
             ORDER BY last_opened_at DESC LIMIT ?1",
        )?;
        let rows = statement.query_map(params![limit], map_project)?;
        let mut projects = Vec::new();
        for row in rows {
            projects.push(row?);
        }
        Ok(projects)
    }

    pub fn update_project_config(
        &self,
        id: &str,
        config: &ProjectConfigInput,
    ) -> AppResult<Project> {
        let args = serde_json::to_string(&config.run_args)?;
        let conn = self.lock()?;
        conn.execute(
            "UPDATE projects SET entry_point = ?1, run_args = ?2, timeout_ms = ?3, tracing = ?4, \
             python_path = ?5 WHERE id = ?6",
            params![
                config.entry_point,
                args,
                config.timeout_ms.clamp(1_000, 600_000) as i64,
                config.tracing as i64,
                config.python_path,
                id
            ],
        )?;
        drop(conn);
        self.get_project(id)
    }

    pub fn set_consent(&self, id: &str, granted: bool) -> AppResult<Project> {
        {
            let conn = self.lock()?;
            conn.execute(
                "UPDATE projects SET consent = ?1 WHERE id = ?2",
                params![granted as i64, id],
            )?;
        }
        self.get_project(id)
    }

    // -- sessions ----------------------------------------------------------

    pub fn insert_session(&self, session: &Session, trace_file: &str) -> AppResult<()> {
        let args = serde_json::to_string(&session.args)?;
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO sessions (id, project_id, experiment_id, kind, label, command, args, stdin, \
             cwd, entry_file, python, status, exit_code, started_at, finished_at, duration_ms, \
             peak_memory_bytes, timeout_ms, error, stdout, stderr, trace_events, trace_truncated, \
             trace_file) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, \
             ?16, ?17, ?18, ?19, '', '', 0, 0, ?20)",
            params![
                session.id,
                session.project_id,
                session.experiment_id,
                session.kind,
                session.label,
                session.command,
                args,
                session.stdin,
                session.cwd,
                session.entry_file,
                session.python,
                session.status,
                session.exit_code,
                session.started_at,
                session.finished_at,
                session.duration_ms,
                session.peak_memory_bytes,
                session.timeout_ms,
                session.error,
                trace_file,
            ],
        )?;
        Ok(())
    }

    pub fn finish_session(
        &self,
        id: &str,
        status: &str,
        exit_code: Option<i32>,
        finished_at: i64,
        duration_ms: i64,
        peak_memory_bytes: Option<i64>,
        error: Option<&str>,
        stdout: &str,
        stderr: &str,
        trace_events: i64,
        trace_truncated: bool,
    ) -> AppResult<()> {
        let conn = self.lock()?;
        conn.execute(
            "UPDATE sessions SET status = ?1, exit_code = ?2, finished_at = ?3, duration_ms = ?4, \
             peak_memory_bytes = ?5, error = ?6, stdout = ?7, stderr = ?8, trace_events = ?9, \
             trace_truncated = ?10 WHERE id = ?11",
            params![
                status,
                exit_code,
                finished_at,
                duration_ms,
                peak_memory_bytes,
                error,
                stdout,
                stderr,
                trace_events,
                trace_truncated as i64,
                id
            ],
        )?;
        Ok(())
    }

    pub fn get_session(&self, id: &str) -> AppResult<Session> {
        let conn = self.lock()?;
        let sql = format!("SELECT {} FROM sessions WHERE id = ?1", SESSION_COLUMNS);
        conn.query_row(&sql, params![id], map_session)
            .optional()?
            .ok_or_else(|| AppError::not_found("Session not found"))
    }

    pub fn list_sessions(&self, project_id: &str, limit: u32) -> AppResult<Vec<Session>> {
        let conn = self.lock()?;
        let sql = format!(
            "SELECT {} FROM sessions WHERE project_id = ?1 ORDER BY started_at DESC LIMIT ?2",
            SESSION_COLUMNS
        );
        let mut statement = conn.prepare(&sql)?;
        let rows = statement.query_map(params![project_id, limit], map_session)?;
        let mut sessions = Vec::new();
        for row in rows {
            sessions.push(row?);
        }
        Ok(sessions)
    }

    /// Mark runs that were still `running` at startup as crashed. Without a live
    /// execution manager there is no process to reconnect to.
    pub fn reconcile_running_sessions(&self) -> AppResult<usize> {
        let conn = self.lock()?;
        let updated = conn.execute(
            "UPDATE sessions SET status = 'crashed', finished_at = ?1, \
             error = COALESCE(error, 'Stateglass was closed before this execution finished.') \
             WHERE status = 'running'",
            params![now_ms()],
        )?;
        Ok(updated)
    }

    pub fn session_output(&self, id: &str) -> AppResult<SessionOutput> {
        let conn = self.lock()?;
        let (stdout, stderr) = conn
            .query_row(
                "SELECT stdout, stderr FROM sessions WHERE id = ?1",
                params![id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?
            .ok_or_else(|| AppError::not_found("Session not found"))?;
        Ok(SessionOutput {
            session_id: id.to_string(),
            // `len()` is a byte count, matching the cap applied while streaming.
            stdout_truncated: stdout.len() >= MAX_STORED_OUTPUT_BYTES,
            stderr_truncated: stderr.len() >= MAX_STORED_OUTPUT_BYTES,
            stdout,
            stderr,
        })
    }

    // -- trace events ------------------------------------------------------

    pub fn insert_trace_batch(
        &self,
        session_id: &str,
        events: &[RawTraceEvent],
    ) -> AppResult<Vec<TraceEvent>> {
        if events.is_empty() {
            return Ok(Vec::new());
        }
        let mut conn = self.lock()?;
        let tx = conn.transaction()?;
        let mut inserted = Vec::with_capacity(events.len());
        {
            let mut statement = tx.prepare(
                "INSERT INTO trace_events (session_id, seq, ts, kind, frame, parent, depth, file, \
                 line, func, name, value, vtype, changed) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
            )?;
            for event in events {
                statement.execute(params![
                    session_id,
                    event.seq,
                    event.ts,
                    event.kind,
                    event.frame,
                    event.parent,
                    event.depth,
                    event.file,
                    event.line,
                    event.func,
                    event.name,
                    event.value,
                    event.vtype,
                    event.changed.map(|value| value as i64),
                ])?;
                let id = tx.last_insert_rowid();
                inserted.push(TraceEvent {
                    id,
                    session_id: session_id.to_string(),
                    seq: event.seq,
                    ts: event.ts,
                    kind: event.kind.clone(),
                    frame: event.frame,
                    parent: event.parent,
                    depth: event.depth,
                    file: event.file.clone(),
                    line: event.line,
                    func: event.func.clone(),
                    name: event.name.clone(),
                    value: event.value.clone(),
                    vtype: event.vtype.clone(),
                    changed: event.changed,
                });
            }
        }
        tx.commit()?;
        Ok(inserted)
    }

    pub fn trace_event_count(&self, session_id: &str) -> AppResult<i64> {
        let conn = self.lock()?;
        Ok(conn.query_row(
            "SELECT COUNT(*) FROM trace_events WHERE session_id = ?1",
            params![session_id],
            |row| row.get(0),
        )?)
    }

    pub fn list_trace_events(
        &self,
        session_id: &str,
        kinds: &[String],
        limit: u32,
        offset: u32,
        tail: bool,
    ) -> AppResult<TracePage> {
        let conn = self.lock()?;
        let total: i64 = conn.query_row(
            "SELECT COUNT(*) FROM trace_events WHERE session_id = ?1",
            params![session_id],
            |row| row.get(0),
        )?;

        let mut sql = format!(
            "SELECT {} FROM trace_events WHERE session_id = ?1",
            TRACE_COLUMNS
        );
        let mut values: Vec<rusqlite::types::Value> = vec![session_id.to_string().into()];
        if !kinds.is_empty() {
            sql.push_str(" AND kind IN (");
            for index in 0..kinds.len() {
                if index > 0 {
                    sql.push(',');
                }
                sql.push_str(&format!("?{}", index + 2));
                values.push(kinds[index].clone().into());
            }
            sql.push(')');
        }
        let next = values.len() + 1;
        // `tail` fetches the newest events (useful for long sessions) and then
        // restores chronological order for the UI.
        let direction = if tail { "DESC" } else { "ASC" };
        sql.push_str(&format!(
            " ORDER BY seq {} LIMIT ?{} OFFSET ?{}",
            direction, next, next + 1
        ));
        values.push((limit.clamp(1, 50_000) as i64).into());
        values.push((offset as i64).into());

        let mut statement = conn.prepare(&sql)?;
        let rows = statement.query_map(params_from_iter(values.iter()), map_trace_event)?;
        let mut events = Vec::new();
        for row in rows {
            events.push(row?);
        }
        if tail {
            events.reverse();
        }
        let returned = events.len();
        Ok(TracePage {
            events,
            total,
            returned,
        })
    }

    pub fn trace_stats(&self, session_id: &str) -> AppResult<TraceStats> {
        let conn = self.lock()?;
        let total: i64 = conn.query_row(
            "SELECT COUNT(*) FROM trace_events WHERE session_id = ?1",
            params![session_id],
            |row| row.get(0),
        )?;
        let truncated: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM trace_events WHERE session_id = ?1 AND kind = 'truncated')",
            params![session_id],
            |row| row.get(0),
        )?;
        let mut kinds = Vec::new();
        {
            let mut statement = conn.prepare(
                "SELECT kind, COUNT(*) FROM trace_events WHERE session_id = ?1 GROUP BY kind \
                 ORDER BY COUNT(*) DESC",
            )?;
            let rows = statement.query_map(params![session_id], |row| {
                Ok(KindCount {
                    kind: row.get(0)?,
                    count: row.get(1)?,
                })
            })?;
            for row in rows {
                kinds.push(row?);
            }
        }
        let mut variables = Vec::new();
        {
            let mut statement = conn.prepare(
                "SELECT DISTINCT name FROM trace_events WHERE session_id = ?1 AND kind = 'var' \
                 AND name IS NOT NULL ORDER BY name LIMIT 600",
            )?;
            let rows = statement.query_map(params![session_id], |row| row.get::<_, String>(0))?;
            for row in rows {
                let name = row?;
                if !(name.starts_with("__") && name.ends_with("__")) {
                    variables.push(name);
                }
            }
        }
        Ok(TraceStats {
            total,
            kinds,
            variables,
            truncated,
        })
    }

    pub fn variables_at(
        &self,
        session_id: &str,
        seq: Option<i64>,
    ) -> AppResult<Vec<VariableSnapshot>> {
        let conn = self.lock()?;
        let sql = match seq {
            Some(_) => {
                "SELECT e.name, e.value, e.vtype, e.file, e.line, e.func, e.seq \
                 FROM trace_events e JOIN (SELECT name, MAX(seq) AS m FROM trace_events \
                 WHERE session_id = ?1 AND kind IN ('var', 'del') AND name IS NOT NULL AND seq <= ?2 \
                 GROUP BY name) latest ON e.name = latest.name AND e.seq = latest.m \
                 WHERE e.session_id = ?1 AND e.kind = 'var' ORDER BY e.name"
            }
            None => {
                "SELECT e.name, e.value, e.vtype, e.file, e.line, e.func, e.seq \
                 FROM trace_events e JOIN (SELECT name, MAX(seq) AS m FROM trace_events \
                 WHERE session_id = ?1 AND kind IN ('var', 'del') AND name IS NOT NULL \
                 GROUP BY name) latest ON e.name = latest.name AND e.seq = latest.m \
                 WHERE e.session_id = ?1 AND e.kind = 'var' ORDER BY e.name"
            }
        };
        let mut statement = conn.prepare(sql)?;
        let mapper = |row: &Row<'_>| -> rusqlite::Result<VariableSnapshot> {
            Ok(VariableSnapshot {
                name: row.get(0)?,
                value: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                vtype: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                file: row.get(3)?,
                line: row.get(4)?,
                func: row.get(5)?,
                seq: row.get(6)?,
            })
        };
        let rows = match seq {
            Some(seq) => statement.query_map(params![session_id, seq], mapper)?,
            None => statement.query_map(params![session_id], mapper)?,
        };
        let mut out = Vec::new();
        for row in rows {
            let snapshot = row?;
            if snapshot.name.starts_with("__") && snapshot.name.ends_with("__") {
                continue;
            }
            out.push(snapshot);
        }
        Ok(out)
    }

    pub fn variable_history(
        &self,
        session_id: &str,
        name: &str,
        limit: u32,
    ) -> AppResult<Vec<TraceEvent>> {
        let conn = self.lock()?;
        let sql = format!(
            "SELECT {} FROM (SELECT * FROM trace_events WHERE session_id = ?1 AND kind = 'var' \
             AND name = ?2 ORDER BY seq DESC LIMIT ?3) ORDER BY seq ASC",
            TRACE_COLUMNS
        );
        let mut statement = conn.prepare(&sql)?;
        let rows = statement.query_map(params![session_id, name, limit], map_trace_event)?;
        let mut events = Vec::new();
        for row in rows {
            events.push(row?);
        }
        Ok(events)
    }

    pub fn latest_var_before(
        &self,
        session_id: &str,
        name: &str,
        seq: i64,
        func: Option<&str>,
    ) -> AppResult<Option<TraceEvent>> {
        let conn = self.lock()?;
        let sql = format!(
            "SELECT {} FROM trace_events WHERE session_id = ?1 AND kind = 'var' AND name = ?2 \
             AND seq < ?3 AND (?4 IS NULL OR func = ?4) ORDER BY seq DESC LIMIT 1",
            TRACE_COLUMNS
        );
        let found = conn
            .query_row(&sql, params![session_id, name, seq, func], map_trace_event)
            .optional()?;
        if found.is_some() {
            return Ok(found);
        }
        let sql = format!(
            "SELECT {} FROM trace_events WHERE session_id = ?1 AND kind = 'var' AND name = ?2 \
             AND seq < ?3 ORDER BY seq DESC LIMIT 1",
            TRACE_COLUMNS
        );
        Ok(conn
            .query_row(&sql, params![session_id, name, seq], map_trace_event)
            .optional()?)
    }

    pub fn final_variables(&self, session_id: &str) -> AppResult<Vec<(String, String, String)>> {
        let conn = self.lock()?;
        let mut statement = conn.prepare(
            "SELECT e.name, e.value, e.vtype FROM trace_events e JOIN \
             (SELECT MAX(id) AS id FROM trace_events WHERE session_id = ?1 AND \
              kind IN ('var', 'del') GROUP BY name) latest ON e.id = latest.id \
              WHERE e.kind = 'var' ORDER BY e.name",
        )?;
        let rows = statement.query_map(params![session_id], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                row.get::<_, Option<String>>(2)?.unwrap_or_default(),
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let entry = row?;
            if entry.0.starts_with("__") && entry.0.ends_with("__") {
                continue;
            }
            out.push(entry);
        }
        Ok(out)
    }

    // -- assignments -------------------------------------------------------

    pub fn replace_assignments(
        &self,
        workspace_id: &str,
        records: &[AssignmentRecord],
    ) -> AppResult<()> {
        let mut conn = self.lock()?;
        let tx = conn.transaction()?;
        tx.execute(
            "DELETE FROM assignments WHERE workspace_id = ?1",
            params![workspace_id],
        )?;
        {
            let mut statement = tx.prepare(
                "INSERT OR REPLACE INTO assignments (workspace_id, file, line, col, func, target, \
                 sources, callee, kind) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            )?;
            for record in records {
                let sources = serde_json::to_string(&record.sources)?;
                statement.execute(params![
                    workspace_id,
                    record.file,
                    record.line,
                    record.col,
                    record.func,
                    record.target,
                    sources,
                    record.callee,
                    record.kind,
                ])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn assignments_for(
        &self,
        workspace_id: &str,
        file: Option<&str>,
    ) -> AppResult<Vec<AssignmentRecord>> {
        let conn = self.lock()?;
        let mut records = Vec::new();
        let mapper = |row: &Row<'_>| -> rusqlite::Result<AssignmentRecord> {
            let sources: String = row.get(5)?;
            Ok(AssignmentRecord {
                file: row.get(0)?,
                line: row.get(1)?,
                col: row.get(2)?,
                func: row.get(3)?,
                target: row.get(4)?,
                sources: serde_json::from_str(&sources).unwrap_or_default(),
                callee: row.get(6)?,
                kind: row.get(7)?,
            })
        };
        match file {
            Some(file) => {
                let mut statement = conn.prepare(
                    "SELECT file, line, col, func, target, sources, callee, kind FROM assignments \
                     WHERE workspace_id = ?1 AND file = ?2 ORDER BY line ASC",
                )?;
                let rows = statement.query_map(params![workspace_id, file], mapper)?;
                for row in rows {
                    records.push(row?);
                }
            }
            None => {
                let mut statement = conn.prepare(
                    "SELECT file, line, col, func, target, sources, callee, kind FROM assignments \
                     WHERE workspace_id = ?1 ORDER BY file, line ASC",
                )?;
                let rows = statement.query_map(params![workspace_id], mapper)?;
                for row in rows {
                    records.push(row?);
                }
            }
        }
        Ok(records)
    }

    // -- experiments -------------------------------------------------------

    pub fn insert_experiment(&self, experiment: &Experiment) -> AppResult<()> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO experiments (id, project_id, baseline_session_id, name, note, path, \
             created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                experiment.id,
                experiment.project_id,
                experiment.baseline_session_id,
                experiment.name,
                experiment.note,
                experiment.path,
                experiment.created_at,
                experiment.updated_at,
            ],
        )?;
        Ok(())
    }

    pub fn get_experiment(&self, id: &str) -> AppResult<Experiment> {
        let conn = self.lock()?;
        conn.query_row(
            "SELECT id, project_id, baseline_session_id, name, note, path, created_at, updated_at \
             FROM experiments WHERE id = ?1",
            params![id],
            map_experiment,
        )
        .optional()?
        .ok_or_else(|| AppError::not_found("Experiment not found"))
    }

    pub fn list_experiments(&self, project_id: &str) -> AppResult<Vec<Experiment>> {
        let conn = self.lock()?;
        let mut statement = conn.prepare(
            "SELECT id, project_id, baseline_session_id, name, note, path, created_at, updated_at \
             FROM experiments WHERE project_id = ?1 ORDER BY created_at DESC",
        )?;
        let rows = statement.query_map(params![project_id], map_experiment)?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    // -- settings ----------------------------------------------------------

    pub fn get_setting(&self, key: &str) -> AppResult<Option<String>> {
        let conn = self.lock()?;
        Ok(conn
            .query_row(
                "SELECT value FROM settings WHERE key = ?1",
                params![key],
                |row| row.get(0),
            )
            .optional()?)
    }

    pub fn set_setting(&self, key: &str, value: &str) -> AppResult<()> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO settings (key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Row mappers
// ---------------------------------------------------------------------------

fn map_project(row: &Row<'_>) -> rusqlite::Result<Project> {
    let args: String = row.get(5)?;
    Ok(Project {
        id: row.get(0)?,
        name: row.get(1)?,
        root_path: row.get(2)?,
        language: row.get(3)?,
        entry_point: row.get(4)?,
        run_args: serde_json::from_str(&args).unwrap_or_default(),
        timeout_ms: row.get::<_, i64>(6)? as u64,
        tracing: row.get::<_, i64>(7)? != 0,
        consent_granted: row.get::<_, i64>(8)? != 0,
        python_path: row.get(9)?,
        created_at: row.get(10)?,
        last_opened_at: row.get(11)?,
    })
}

fn map_session(row: &Row<'_>) -> rusqlite::Result<Session> {
    let args: String = row.get(6)?;
    Ok(Session {
        id: row.get(0)?,
        project_id: row.get(1)?,
        experiment_id: row.get(2)?,
        kind: row.get(3)?,
        label: row.get(4)?,
        command: row.get(5)?,
        args: serde_json::from_str(&args).unwrap_or_default(),
        stdin: row.get(7)?,
        cwd: row.get(8)?,
        entry_file: row.get(9)?,
        python: row.get(10)?,
        status: row.get(11)?,
        exit_code: row.get(12)?,
        started_at: row.get(13)?,
        finished_at: row.get(14)?,
        duration_ms: row.get(15)?,
        peak_memory_bytes: row.get(16)?,
        timeout_ms: row.get(17)?,
        error: row.get(18)?,
        stdout_preview: row.get::<_, Option<String>>(19)?.unwrap_or_default(),
        stderr_preview: row.get::<_, Option<String>>(20)?.unwrap_or_default(),
        stdout_bytes: row.get::<_, Option<i64>>(21)?.unwrap_or(0),
        stderr_bytes: row.get::<_, Option<i64>>(22)?.unwrap_or(0),
        trace_event_count: row.get(23)?,
        trace_truncated: row.get::<_, i64>(24)? != 0,
    })
}

fn map_trace_event(row: &Row<'_>) -> rusqlite::Result<TraceEvent> {
    Ok(TraceEvent {
        id: row.get(0)?,
        session_id: row.get(1)?,
        seq: row.get(2)?,
        ts: row.get(3)?,
        kind: row.get(4)?,
        frame: row.get(5)?,
        parent: row.get(6)?,
        depth: row.get(7)?,
        file: row.get(8)?,
        line: row.get(9)?,
        func: row.get(10)?,
        name: row.get(11)?,
        value: row.get(12)?,
        vtype: row.get(13)?,
        changed: row.get::<_, Option<i64>>(14)?.map(|value| value != 0),
    })
}

fn map_experiment(row: &Row<'_>) -> rusqlite::Result<Experiment> {
    Ok(Experiment {
        id: row.get(0)?,
        project_id: row.get(1)?,
        baseline_session_id: row.get(2)?,
        name: row.get(3)?,
        note: row.get(4)?,
        path: row.get(5)?,
        created_at: row.get(6)?,
        updated_at: row.get(7)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn project(root: &str) -> Project {
        Project {
            id: new_id(),
            name: "demo".into(),
            root_path: root.into(),
            language: "python".into(),
            entry_point: Some("main.py".into()),
            run_args: vec!["--flag".into()],
            timeout_ms: 5000,
            tracing: true,
            consent_granted: true,
            python_path: None,
            created_at: now_ms(),
            last_opened_at: now_ms(),
        }
    }

    #[test]
    fn projects_upsert_by_root_path() {
        let storage = Storage::open_in_memory().unwrap();
        let mut first = project("/tmp/demo");
        storage.upsert_project(&first).unwrap();
        let reloaded = storage.get_project_by_root("/tmp/demo").unwrap().unwrap();
        assert_eq!(reloaded.id, first.id);
        assert_eq!(reloaded.run_args, vec!["--flag"]);

        first.name = "renamed".into();
        storage.upsert_project(&first).unwrap();
        let projects = storage.list_projects(10).unwrap();
        assert_eq!(projects.len(), 1);
        assert_eq!(projects[0].name, "renamed");
    }

    #[test]
    fn project_config_is_persisted() {
        let storage = Storage::open_in_memory().unwrap();
        let project = project("/tmp/config");
        storage.upsert_project(&project).unwrap();
        let updated = storage
            .update_project_config(
                &project.id,
                &ProjectConfigInput {
                    entry_point: Some("app.py".into()),
                    run_args: vec!["--debug".into(), "2".into()],
                    timeout_ms: 30_000,
                    tracing: false,
                    python_path: Some("/usr/bin/python3".into()),
                },
            )
            .unwrap();
        assert_eq!(updated.entry_point.as_deref(), Some("app.py"));
        assert_eq!(updated.run_args, vec!["--debug", "2"]);
        assert!(!updated.tracing);
        assert_eq!(updated.timeout_ms, 30_000);
    }

    #[test]
    fn trace_queries_return_history_and_snapshots() {
        let storage = Storage::open_in_memory().unwrap();
        let session = test_session();
        storage.insert_session(&session, "/tmp/trace.ndjson").unwrap();
        let events = vec![
            raw_var(1, "x", "1", 3),
            raw_var(2, "y", "2", 4),
            raw_var(3, "x", "5", 7),
            raw_var(4, "z", "9", 8),
        ];
        storage.insert_trace_batch(&session.id, &events).unwrap();

        let history = storage.variable_history(&session.id, "x", 50).unwrap();
        assert_eq!(history.len(), 2);
        assert_eq!(history[1].value.as_deref(), Some("5"));

        let snapshot = storage.variables_at(&session.id, Some(3)).unwrap();
        let names: Vec<_> = snapshot.iter().map(|entry| entry.name.as_str()).collect();
        assert_eq!(names, vec!["x", "y"]);
        assert_eq!(snapshot[0].value, "5");

        let final_vars = storage.final_variables(&session.id).unwrap();
        assert_eq!(final_vars.len(), 3);

        let latest = storage
            .latest_var_before(&session.id, "x", 10, Some("f"))
            .unwrap()
            .unwrap();
        assert_eq!(latest.seq, 3);
    }

    #[test]
    fn deleted_variables_drop_out_of_snapshots() {
        let storage = Storage::open_in_memory().unwrap();
        let session = test_session();
        storage.insert_session(&session, "/tmp/trace.ndjson").unwrap();
        let mut deletion = raw_var(3, "x", "", 5);
        deletion.kind = "del".into();
        deletion.value = None;
        deletion.vtype = None;
        deletion.changed = None;
        let events = vec![raw_var(1, "x", "1", 3), raw_var(2, "y", "2", 4), deletion];
        storage.insert_trace_batch(&session.id, &events).unwrap();

        let names = |snapshot: Vec<VariableSnapshot>| -> Vec<String> {
            snapshot.into_iter().map(|entry| entry.name).collect()
        };
        assert_eq!(names(storage.variables_at(&session.id, Some(1)).unwrap()), vec!["x"]);
        assert_eq!(
            names(storage.variables_at(&session.id, Some(2)).unwrap()),
            vec!["x", "y"]
        );
        assert_eq!(names(storage.variables_at(&session.id, None).unwrap()), vec!["y"]);
        assert!(storage
            .final_variables(&session.id)
            .unwrap()
            .iter()
            .all(|entry| entry.0 != "x"));
    }

    #[test]
    fn assignments_are_replaced_atomically() {
        let storage = Storage::open_in_memory().unwrap();
        let record = AssignmentRecord {
            file: "a.py".into(),
            line: 3,
            col: 0,
            func: "main".into(),
            target: "total".into(),
            sources: vec!["price".into(), "qty".into()],
            callee: None,
            kind: "assign".into(),
        };
        storage.replace_assignments("ws", &[record]).unwrap();
        let loaded = storage.assignments_for("ws", None).unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].sources, vec!["price", "qty"]);
        storage.replace_assignments("ws", &[]).unwrap();
        assert!(storage.assignments_for("ws", None).unwrap().is_empty());
    }

    #[test]
    fn sessions_round_trip_with_output() {
        let storage = Storage::open_in_memory().unwrap();
        let session = test_session();
        storage.insert_session(&session, "/tmp/trace.ndjson").unwrap();
        storage
            .finish_session(
                &session.id,
                "ok",
                Some(0),
                now_ms(),
                42,
                Some(1024),
                None,
                "hello\n",
                "",
                12,
                false,
            )
            .unwrap();
        let loaded = storage.get_session(&session.id).unwrap();
        assert_eq!(loaded.status, "ok");
        assert_eq!(loaded.duration_ms, Some(42));
        assert_eq!(loaded.stdout_bytes, 6);
        let output = storage.session_output(&session.id).unwrap();
        assert_eq!(output.stdout, "hello\n");
        assert_eq!(storage.list_sessions(&session.project_id, 10).unwrap().len(), 1);
    }

    #[test]
    fn trace_pages_can_tail_the_newest_events() {
        let storage = Storage::open_in_memory().unwrap();
        let session = test_session();
        storage.insert_session(&session, "/tmp/trace.ndjson").unwrap();
        let events: Vec<_> = (1..=10)
            .map(|seq| raw_var(seq, "x", &seq.to_string(), seq))
            .collect();
        storage.insert_trace_batch(&session.id, &events).unwrap();

        let head = storage
            .list_trace_events(&session.id, &[], 3, 0, false)
            .unwrap();
        assert_eq!(
            head.events.iter().map(|event| event.seq).collect::<Vec<_>>(),
            vec![1, 2, 3]
        );
        assert_eq!(head.total, 10);

        let tail = storage
            .list_trace_events(&session.id, &[], 3, 0, true)
            .unwrap();
        assert_eq!(
            tail.events.iter().map(|event| event.seq).collect::<Vec<_>>(),
            vec![8, 9, 10]
        );
        assert_eq!(tail.returned, 3);
    }

    #[test]
    fn trace_stats_reports_the_truncation_marker() {
        let storage = Storage::open_in_memory().unwrap();
        let session = test_session();
        storage.insert_session(&session, "/tmp/trace.ndjson").unwrap();
        assert!(!storage.trace_stats(&session.id).unwrap().truncated);

        storage
            .insert_trace_batch(
                &session.id,
                &[RawTraceEvent {
                    seq: 11,
                    ts: 110,
                    kind: "truncated".into(),
                    value: Some("event limit reached".into()),
                    ..Default::default()
                }],
            )
            .unwrap();
        assert!(storage.trace_stats(&session.id).unwrap().truncated);
    }

    #[test]
    fn session_output_byte_counts_handle_multibyte_text() {
        let storage = Storage::open_in_memory().unwrap();
        let session = test_session();
        storage.insert_session(&session, "/tmp/trace.ndjson").unwrap();
        storage
            .finish_session(
                &session.id,
                "ok",
                Some(0),
                now_ms(),
                10,
                None,
                None,
                "héllo\n",
                "wörld\n",
                0,
                false,
            )
            .unwrap();
        let loaded = storage.get_session(&session.id).unwrap();
        // "héllo\n" is 6 characters but 7 UTF-8 bytes.
        assert_eq!(loaded.stdout_bytes, 7);
        assert_eq!(loaded.stderr_bytes, 7);
    }

    #[test]
    fn stale_running_sessions_are_reconciled() {
        let storage = Storage::open_in_memory().unwrap();
        let mut session = test_session();
        session.status = "running".into();
        storage.insert_session(&session, "/tmp/t.ndjson").unwrap();
        let count = storage.reconcile_running_sessions().unwrap();
        assert_eq!(count, 1);
        let loaded = storage.get_session(&session.id).unwrap();
        assert_eq!(loaded.status, "crashed");
        assert!(loaded.error.unwrap_or_default().contains("closed"));
    }

    fn test_session() -> Session {
        Session {
            id: new_id(),
            project_id: "p1".into(),
            experiment_id: None,
            kind: "baseline".into(),
            label: None,
            command: "python3 main.py".into(),
            args: vec![],
            stdin: None,
            cwd: "/tmp/demo".into(),
            entry_file: Some("main.py".into()),
            python: "python3".into(),
            status: "running".into(),
            exit_code: None,
            started_at: now_ms(),
            finished_at: None,
            duration_ms: None,
            peak_memory_bytes: None,
            timeout_ms: 20_000,
            error: None,
            stdout_preview: String::new(),
            stderr_preview: String::new(),
            stdout_bytes: 0,
            stderr_bytes: 0,
            trace_event_count: 0,
            trace_truncated: false,
        }
    }

    fn raw_var(seq: i64, name: &str, value: &str, line: i64) -> RawTraceEvent {
        RawTraceEvent {
            seq,
            ts: seq * 10,
            kind: "var".into(),
            frame: Some(1),
            file: Some("/tmp/demo/a.py".into()),
            line: Some(line),
            func: Some("f".into()),
            name: Some(name.into()),
            value: Some(value.into()),
            vtype: Some("int".into()),
            changed: Some(true),
            ..Default::default()
        }
    }
}
