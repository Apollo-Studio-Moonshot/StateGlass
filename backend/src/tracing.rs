//! Trace ingestion helpers and data-flow graph construction.
//!
//! Two sources of truth are joined here:
//! * runtime snapshots (`var` events emitted by the Python tracer), and
//! * static assignment metadata produced by the AST analyzer.
//!
//! The join is deliberately conservative: when a static assignment cannot be
//! matched to a runtime change, the graph falls back to showing the runtime
//! line attribution instead of inventing edges.

use crate::error::AppResult;
use crate::models::{DataFlow, FlowAssignment, FlowEdge, FlowNode, RawTraceEvent, Session};
use crate::storage::Storage;
use std::collections::{HashMap, HashSet};

/// Maximum number of trace events retained for one execution (defensive cap).
pub const TRACE_MAX_EVENTS: i64 = 200_000;
pub const TRACE_VALUE_LENGTH: i64 = 180;
pub const TRACE_MAX_DEPTH: i64 = 40;
pub const TRACE_MAX_LOCALS: i64 = 64;

/// Split a growing NDJSON buffer into complete events.
///
/// Lines that do not parse are dropped; the tracer is the only writer, so this
/// should only happen for a partially flushed final line.
pub fn take_events(pending: &mut Vec<u8>, finalize: bool) -> Vec<RawTraceEvent> {
    let mut events = Vec::new();
    loop {
        let Some(position) = pending.iter().position(|byte| *byte == b'\n') else {
            break;
        };
        let line: Vec<u8> = pending.drain(..=position).collect();
        let text = String::from_utf8_lossy(&line);
        let text = text.trim();
        if text.is_empty() {
            continue;
        }
        if let Ok(event) = serde_json::from_str::<RawTraceEvent>(text) {
            events.push(event);
        }
    }
    if finalize && !pending.is_empty() {
        let remaining = String::from_utf8_lossy(pending).trim().to_string();
        pending.clear();
        if !remaining.is_empty() {
            if let Ok(event) = serde_json::from_str::<RawTraceEvent>(&remaining) {
                events.push(event);
            }
        }
    }
    events
}

pub fn relativize(file: &str, root: &str) -> String {
    let file_normalized = file.replace('\\', "/");
    let root_normalized = root.replace('\\', "/");
    let root_trimmed = root_normalized.trim_end_matches('/');
    if root_trimmed.is_empty() {
        return file_normalized;
    }
    // Require a path-component boundary so `/work/demo2/a.py` is not treated as
    // belonging to `/work/demo`.
    match file_normalized.strip_prefix(root_trimmed) {
        Some(rest) if rest.is_empty() => file_normalized,
        Some(rest) if rest.starts_with('/') => {
            let relative = rest.trim_start_matches('/');
            if relative.is_empty() {
                file_normalized
            } else {
                relative.to_string()
            }
        }
        _ => file_normalized,
    }
}


/// Build the data-flow graph for one variable in one session.
pub fn build_data_flow(
    storage: &Storage,
    session: &Session,
    variable: &str,
) -> AppResult<DataFlow> {
    const MAX_TARGET_STEPS: usize = 24;
    const MAX_INPUT_EDGES: usize = 120;

    let note_default = "Edges are inferred by joining AST assignment metadata with runtime variable snapshots. \
        Values are captured per source line; object mutation is observed through summarized values."
        .to_string();

    let history = storage.variable_history(&session.id, variable, 400)?;
    if history.is_empty() {
        return Ok(DataFlow {
            variable: variable.to_string(),
            nodes: Vec::new(),
            edges: Vec::new(),
            assignment_sites: Vec::new(),
            truncated: false,
            note: format!(
                "No recorded changes for “{}”. It may be unchanged, out of the traced scope, or beyond the event limit.",
                variable
            ),
        });
    }

    let start = history.len().saturating_sub(MAX_TARGET_STEPS);
    let recent = &history[start..];
    let workspace_id = session
        .experiment_id
        .clone()
        .unwrap_or_else(|| session.project_id.clone());
    let assignments = storage.assignments_for(&workspace_id, None)?;

    let mut by_file: HashMap<String, Vec<&crate::models::AssignmentRecord>> = HashMap::new();
    for assignment in &assignments {
        by_file
            .entry(assignment.file.clone())
            .or_default()
            .push(assignment);
    }

    let mut nodes: Vec<FlowNode> = Vec::new();
    let mut edges: Vec<FlowEdge> = Vec::new();
    let mut node_ids: HashSet<String> = HashSet::new();
    let mut edge_ids: HashSet<String> = HashSet::new();
    let mut sites: Vec<FlowAssignment> = Vec::new();
    let mut site_keys: HashSet<String> = HashSet::new();
    let mut previous_target: Option<String> = None;

    for (index, event) in recent.iter().enumerate() {
        let node_id = format!("t-{}", event.seq);
        let step = index as i64;
        let relative = event
            .file
            .as_deref()
            .map(|file| relativize(file, &session.cwd))
            .unwrap_or_default();

        insert_node(&mut nodes, &mut node_ids, FlowNode {
            id: node_id.clone(),
            label: variable.to_string(),
            value: event.value.clone().unwrap_or_default(),
            vtype: event.vtype.clone().unwrap_or_default(),
            file: event.file.clone(),
            line: event.line,
            func: event.func.clone(),
            seq: event.seq,
            ts: event.ts,
            step,
            role: "target".to_string(),
        });

        if let Some(previous) = previous_target.take() {
            let edge_id = format!("e-u-{}-{}", previous, node_id);
            if edge_ids.insert(edge_id.clone()) {
                edges.push(FlowEdge {
                    id: edge_id,
                    source: previous,
                    target: node_id.clone(),
                    label: "update".to_string(),
                    kind: "update".to_string(),
                });
            }
        }

        let candidates = by_file.get(&relative);
        let mut matched: Option<&crate::models::AssignmentRecord> = None;
        if let Some(candidates) = candidates {
            let same_func: Vec<_> = candidates
                .iter()
                .copied()
                .filter(|assignment| assignment.target == variable)
                .filter(|assignment| assignment.func == event.func.as_deref().unwrap_or(""))
                .collect();
            let event_line = event.line.unwrap_or(0);
            matched = same_func
                .iter()
                .copied()
                .find(|assignment| assignment.line == event_line)
                .or_else(|| {
                    same_func
                        .iter()
                        .copied()
                        .filter(|assignment| assignment.line <= event_line)
                        .max_by_key(|assignment| assignment.line)
                });
        }

        let site_key = format!(
            "{}:{}:{}:{}",
            relative,
            event.func.as_deref().unwrap_or(""),
            event.line.unwrap_or(0),
            variable
        );
        if site_keys.insert(site_key.clone()) {
            sites.push(FlowAssignment {
                file: relative.clone(),
                line: event.line.unwrap_or(0),
                func: event.func.clone().unwrap_or_default(),
                target: variable.to_string(),
                sources: matched.map(|assignment| assignment.sources.clone()).unwrap_or_default(),
                callee: matched.and_then(|assignment| assignment.callee.clone()),
                kind: matched
                    .map(|assignment| assignment.kind.clone())
                    .unwrap_or_else(|| "runtime".to_string()),
                matched: matched.is_some(),
            });
        }

        if let Some(assignment) = matched {
            if edges.len() < MAX_INPUT_EDGES {
                for source in &assignment.sources {
                    if source == variable || source.len() > 120 {
                        continue;
                    }
                    let Some(upstream) =
                        storage.latest_var_before(&session.id, source, event.seq, event.func.as_deref())?
                    else {
                        continue;
                    };
                    let input_id = format!("i-{}-{}", source, upstream.seq);
                    if !node_ids.contains(&input_id) {
                        insert_node(&mut nodes, &mut node_ids, FlowNode {
                            id: input_id.clone(),
                            label: source.clone(),
                            value: upstream.value.clone().unwrap_or_default(),
                            vtype: upstream.vtype.clone().unwrap_or_default(),
                            file: upstream.file.clone(),
                            line: upstream.line,
                            func: upstream.func.clone(),
                            seq: upstream.seq,
                            ts: upstream.ts,
                            step: (index as i64 - 1).max(0),
                            role: "input".to_string(),
                        });
                    }
                    let edge_id = format!("e-r-{}-{}", input_id, node_id);
                    if edge_ids.insert(edge_id.clone()) {
                        edges.push(FlowEdge {
                            id: edge_id,
                            source: input_id,
                            target: node_id.clone(),
                            label: source.clone(),
                            kind: "read".to_string(),
                        });
                    }
                }
            }
        }

        previous_target = Some(node_id);
    }

    let note = if assignments.is_empty() {
        format!(
            "{} Static analysis found no assignments for this project, so only runtime changes are shown.",
            note_default
        )
    } else if sites.iter().all(|site| !site.matched) {
        format!(
            "{} Runtime changes could not be matched to static assignments for this variable (dynamic code, comprehension scopes, or missing source lines).",
            note_default
        )
    } else {
        note_default
    };

    Ok(DataFlow {
        variable: variable.to_string(),
        nodes,
        edges,
        assignment_sites: sites,
        truncated: history.len() >= 400,
        note,
    })
}

fn insert_node(nodes: &mut Vec<FlowNode>, node_ids: &mut HashSet<String>, node: FlowNode) {
    if node_ids.insert(node.id.clone()) {
        nodes.push(node);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(cwd: &str, experiment_id: Option<&str>) -> Session {
        Session {
            id: "s1".into(),
            project_id: "p1".into(),
            experiment_id: experiment_id.map(|value| value.to_string()),
            kind: "baseline".into(),
            label: None,
            command: "python3 main.py".into(),
            args: vec![],
            stdin: None,
            cwd: cwd.into(),
            entry_file: Some("main.py".into()),
            python: "python3".into(),
            status: "ok".into(),
            exit_code: Some(0),
            started_at: 0,
            finished_at: Some(1),
            duration_ms: Some(1),
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

    #[test]
    fn splits_ndjson_across_partial_chunks() {
        let mut pending = Vec::new();
        pending.extend_from_slice(b"{\"seq\":1,\"kind\":\"call\"}\n{\"seq\":2,");
        let first = take_events(&mut pending, false);
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].seq, 1);
        pending.extend_from_slice(b"\"kind\":\"var\",\"name\":\"x\"}\n");
        let second = take_events(&mut pending, false);
        assert_eq!(second.len(), 1);
        assert_eq!(second[0].name.as_deref(), Some("x"));
    }

    #[test]
    fn flushes_a_final_unterminated_line() {
        let mut pending = b"{\"seq\":9,\"kind\":\"session_end\",\"status\":\"ok\"}".to_vec();
        let events = take_events(&mut pending, true);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].status.as_deref(), Some("ok"));
        assert!(pending.is_empty());
    }

    #[test]
    fn relativizes_paths() {
        assert_eq!(relativize("/work/demo/a.py", "/work/demo"), "a.py");
        assert_eq!(relativize("/work/demo/pkg/a.py", "/work/demo/"), "pkg/a.py");
        assert_eq!(relativize("/other/a.py", "/work/demo"), "/other/a.py");
    }

    #[test]
    fn relativize_requires_a_directory_boundary() {
        assert_eq!(
            relativize("/work/demo2/a.py", "/work/demo"),
            "/work/demo2/a.py"
        );
        assert_eq!(
            relativize("C:\\work\\demo2\\a.py", "C:\\work\\demo"),
            "C:/work/demo2/a.py"
        );
        assert_eq!(
            relativize("/work/demo/pkg/a.py", "/work/demo"),
            "pkg/a.py"
        );
    }

    #[test]
    fn builds_edges_from_runtime_and_ast() {
        let storage = Storage::open_in_memory().unwrap();
        let session = session("/work/demo", None);
        storage
            .insert_session(&session, "/tmp/t.ndjson")
            .unwrap();
        let raw = vec![
            RawTraceEvent {
                seq: 1,
                ts: 10,
                kind: "var".into(),
                func: Some("price".into()),
                file: Some("/work/demo/a.py".into()),
                line: Some(2),
                name: Some("base".into()),
                value: Some("100".into()),
                vtype: Some("int".into()),
                ..Default::default()
            },
            RawTraceEvent {
                seq: 2,
                ts: 20,
                kind: "var".into(),
                func: Some("total".into()),
                file: Some("/work/demo/a.py".into()),
                line: Some(8),
                name: Some("total".into()),
                value: Some("110".into()),
                vtype: Some("int".into()),
                ..Default::default()
            },
        ];
        storage.insert_trace_batch(&session.id, &raw).unwrap();
        storage
            .replace_assignments(
                "p1",
                &[crate::models::AssignmentRecord {
                    file: "a.py".into(),
                    line: 8,
                    col: 0,
                    func: "total".into(),
                    target: "total".into(),
                    sources: vec!["base".into()],
                    callee: None,
                    kind: "assign".into(),
                }],
            )
            .unwrap();

        let flow = build_data_flow(&storage, &session, "total").unwrap();
        assert_eq!(flow.nodes.len(), 2);
        assert!(flow.edges.iter().any(|edge| edge.label == "base"));
        assert!(flow.assignment_sites.iter().any(|site| site.matched));
        assert!(!flow.note.is_empty());
    }

    #[test]
    fn experiment_workspace_uses_its_own_assignments() {
        let storage = Storage::open_in_memory().unwrap();
        let session = session("/data/experiments/e1/project", Some("e1"));
        storage.insert_session(&session, "/tmp/t.ndjson").unwrap();
        storage
            .insert_trace_batch(
                &session.id,
                &[RawTraceEvent {
                    seq: 1,
                    ts: 1,
                    kind: "var".into(),
                    func: Some("f".into()),
                    file: Some("/data/experiments/e1/project/a.py".into()),
                    line: Some(3),
                    name: Some("x".into()),
                    value: Some("1".into()),
                    vtype: Some("int".into()),
                    ..Default::default()
                }],
            )
            .unwrap();
        storage
            .replace_assignments(
                "e1",
                &[crate::models::AssignmentRecord {
                    file: "a.py".into(),
                    line: 3,
                    col: 0,
                    func: "f".into(),
                    target: "x".into(),
                    sources: vec![],
                    callee: None,
                    kind: "assign".into(),
                }],
            )
            .unwrap();
        let flow = build_data_flow(&storage, &session, "x").unwrap();
        assert!(flow.assignment_sites.iter().any(|site| site.matched));
    }
}
