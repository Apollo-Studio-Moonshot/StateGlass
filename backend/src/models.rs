//! Serializable data model shared between the Rust backend and the React UI.

use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis() as i64)
        .unwrap_or(0)
}

pub fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

// ---------------------------------------------------------------------------
// Projects
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    pub id: String,
    pub name: String,
    pub root_path: String,
    pub language: String,
    pub entry_point: Option<String>,
    pub run_args: Vec<String>,
    pub timeout_ms: u64,
    pub tracing: bool,
    pub consent_granted: bool,
    pub python_path: Option<String>,
    pub created_at: i64,
    pub last_opened_at: i64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectConfigInput {
    pub entry_point: Option<String>,
    #[serde(default)]
    pub run_args: Vec<String>,
    pub timeout_ms: u64,
    pub tracing: bool,
    pub python_path: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileEntry {
    pub path: String,
    pub name: String,
    pub is_dir: bool,
    pub is_python: bool,
    pub size: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileContent {
    pub path: String,
    pub content: String,
    pub size: u64,
    pub language: String,
    pub modified_at: i64,
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub id: String,
    pub project_id: String,
    pub experiment_id: Option<String>,
    /// `baseline` or `experiment`.
    pub kind: String,
    pub label: Option<String>,
    /// Display form of the executed command, e.g. `python3 main.py --fast`.
    pub command: String,
    pub args: Vec<String>,
    pub stdin: Option<String>,
    pub cwd: String,
    pub entry_file: Option<String>,
    pub python: String,
    pub status: String,
    pub exit_code: Option<i32>,
    pub started_at: i64,
    pub finished_at: Option<i64>,
    pub duration_ms: Option<i64>,
    pub peak_memory_bytes: Option<i64>,
    pub timeout_ms: i64,
    pub error: Option<String>,
    pub stdout_preview: String,
    pub stderr_preview: String,
    pub stdout_bytes: i64,
    pub stderr_bytes: i64,
    pub trace_event_count: i64,
    pub trace_truncated: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionOutput {
    pub session_id: String,
    pub stdout: String,
    pub stderr: String,
    pub stdout_truncated: bool,
    pub stderr_truncated: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunRequest {
    pub project_id: String,
    pub experiment_id: Option<String>,
    pub baseline_session_id: Option<String>,
    pub stdin: Option<String>,
}

// ---------------------------------------------------------------------------
// Trace events
// ---------------------------------------------------------------------------

/// Raw event as emitted by the Python helper (NDJSON).
#[derive(Debug, Clone, Deserialize, Default)]
pub struct RawTraceEvent {
    pub seq: i64,
    #[serde(default)]
    pub ts: i64,
    pub kind: String,
    pub frame: Option<i64>,
    pub parent: Option<i64>,
    pub depth: Option<i64>,
    pub file: Option<String>,
    pub line: Option<i64>,
    pub func: Option<String>,
    pub name: Option<String>,
    pub value: Option<String>,
    pub vtype: Option<String>,
    pub changed: Option<bool>,
    pub exit_code: Option<i32>,
    pub status: Option<String>,
    pub error: Option<String>,
    pub duration_ms: Option<i64>,
    pub events: Option<i64>,
    pub truncated: Option<bool>,
    pub message: Option<String>,
    pub limit: Option<i64>,
    pub root: Option<String>,
    pub entry: Option<String>,
    pub python: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TraceEvent {
    pub id: i64,
    pub session_id: String,
    pub seq: i64,
    pub ts: i64,
    pub kind: String,
    pub frame: Option<i64>,
    pub parent: Option<i64>,
    pub depth: Option<i64>,
    pub file: Option<String>,
    pub line: Option<i64>,
    pub func: Option<String>,
    pub name: Option<String>,
    pub value: Option<String>,
    pub vtype: Option<String>,
    pub changed: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TracePage {
    pub events: Vec<TraceEvent>,
    pub total: i64,
    pub returned: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KindCount {
    pub kind: String,
    pub count: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TraceStats {
    pub total: i64,
    pub kinds: Vec<KindCount>,
    pub variables: Vec<String>,
    pub truncated: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VariableSnapshot {
    pub name: String,
    pub value: String,
    pub vtype: String,
    pub file: Option<String>,
    pub line: Option<i64>,
    pub func: Option<String>,
    pub seq: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FlowNode {
    pub id: String,
    pub label: String,
    pub value: String,
    pub vtype: String,
    pub file: Option<String>,
    pub line: Option<i64>,
    pub func: Option<String>,
    pub seq: i64,
    pub ts: i64,
    pub step: i64,
    /// `target` for the traced variable, `input` for upstream values.
    pub role: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FlowEdge {
    pub id: String,
    pub source: String,
    pub target: String,
    pub label: String,
    /// `read` or `update`.
    pub kind: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FlowAssignment {
    pub file: String,
    pub line: i64,
    pub func: String,
    pub target: String,
    pub sources: Vec<String>,
    pub callee: Option<String>,
    pub kind: String,
    pub matched: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DataFlow {
    pub variable: String,
    pub nodes: Vec<FlowNode>,
    pub edges: Vec<FlowEdge>,
    pub assignment_sites: Vec<FlowAssignment>,
    pub truncated: bool,
    pub note: String,
}

// ---------------------------------------------------------------------------
// Experiments
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Experiment {
    pub id: String,
    pub project_id: String,
    pub baseline_session_id: String,
    pub name: String,
    pub note: Option<String>,
    pub path: String,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExperimentCopyStats {
    pub files: usize,
    pub bytes: u64,
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunMetrics {
    pub duration_ms: Option<i64>,
    pub peak_memory_bytes: Option<i64>,
    pub exit_code: Option<i32>,
    pub status: String,
    pub trace_event_count: i64,
    pub stdout_bytes: i64,
    pub stderr_bytes: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffLine {
    /// `same`, `add`, or `remove`.
    pub kind: String,
    pub baseline_line: Option<usize>,
    pub experiment_line: Option<usize>,
    pub text: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VariableDiff {
    pub name: String,
    pub baseline_value: Option<String>,
    pub baseline_type: Option<String>,
    pub experiment_value: Option<String>,
    pub experiment_type: Option<String>,
    /// `same`, `changed`, `added`, or `removed`.
    pub status: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionComparison {
    pub baseline: Session,
    pub experiment: Session,
    pub baseline_metrics: RunMetrics,
    pub experiment_metrics: RunMetrics,
    pub stdout: Vec<DiffLine>,
    pub stderr: Vec<DiffLine>,
    pub variables: Vec<VariableDiff>,
    pub stdout_divergence: Option<usize>,
    pub warnings: Vec<String>,
}

// ---------------------------------------------------------------------------
// Environment / bootstrap
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PythonRuntime {
    pub path: String,
    pub version: Option<String>,
    pub source: String,
    pub supported: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TraceLimits {
    pub max_events: i64,
    pub value_length: i64,
    pub max_depth: i64,
    pub max_locals: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Bootstrap {
    pub version: String,
    pub data_dir: String,
    pub platform: String,
    pub python: Vec<PythonRuntime>,
    pub selected_python: Option<String>,
    pub trace_limits: TraceLimits,
    pub tracer_path: String,
    pub tracer_available: bool,
    /// Project folder passed on the command line, if any.
    pub initial_project_path: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AnalysisSummary {
    pub files: usize,
    pub assignments: usize,
    pub errors: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct AssignmentRecord {
    pub file: String,
    pub line: i64,
    pub col: i64,
    pub func: String,
    pub target: String,
    pub sources: Vec<String>,
    pub callee: Option<String>,
    pub kind: String,
}
