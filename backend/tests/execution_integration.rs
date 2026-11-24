//! End-to-end backend tests exercising the real Python helper process,
//! SQLite persistence, experiment copies and session comparison.

use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use stateglass_lib::execution::{EventSink, ExecutionManager, RunSpec};
use stateglass_lib::models::{Session, now_ms};
use stateglass_lib::python::{find_tracer, resolve_python};
use stateglass_lib::storage::Storage;
use stateglass_lib::{experiments, project};
use tempfile::tempdir;

struct RecordingSink {
    events: Mutex<Vec<(String, Value)>>,
}

impl RecordingSink {
    fn new() -> Self {
        Self {
            events: Mutex::new(Vec::new()),
        }
    }

    fn names(&self) -> Vec<String> {
        self.events
            .lock()
            .unwrap()
            .iter()
            .map(|(name, _)| name.clone())
            .collect()
    }
}

impl EventSink for RecordingSink {
    fn emit(&self, event: &str, payload: Value) {
        self.events.lock().unwrap().push((event.to_string(), payload));
    }
}

fn tracer_and_python() -> (PathBuf, String) {
    let tracer = find_tracer(None).expect("tracer should exist");
    let (python, _) = resolve_python(None, None, None).expect("python 3.11+ should exist");
    (tracer, python)
}

fn write_project(root: &Path, tax_line: &str) {
    std::fs::write(
        root.join("main.py"),
        r#"from pricing import compute_total

def main():
    price = 100
    quantity = 2
    total = compute_total(price, quantity)
    print(f"total={total}")

if __name__ == "__main__":
    main()
"#,
    )
    .unwrap();
    std::fs::write(
        root.join("pricing.py"),
        format!(
            "TAX = 0.1\n\ndef compute_total(price, quantity):\n    subtotal = price * quantity\n    {}\n    return round(subtotal + tax, 2)\n",
            tax_line
        ),
    )
    .unwrap();
}

fn build_spec(
    project_dir: &Path,
    tracer: PathBuf,
    python: String,
    stdin: Option<String>,
    timeout_ms: u64,
) -> RunSpec {
    RunSpec {
        project_id: "test-project".into(),
        experiment_id: None,
        label: None,
        root: project_dir.to_path_buf(),
        python,
        tracer,
        entry: "main.py".into(),
        args: vec![],
        stdin,
        timeout_ms,
        trace_enabled: true,
    }
}

fn wait_for_finish(storage: &Storage, session_id: &str) -> Session {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let session = storage.get_session(session_id).expect("session exists");
        if session.status != "running" {
            return session;
        }
        if Instant::now() > deadline {
            panic!("session did not finish in time");
        }
        std::thread::sleep(Duration::from_millis(80));
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn traces_a_real_python_execution() {
    let (tracer, python) = tracer_and_python();
    let dir = tempdir().unwrap();
    let project_dir = dir.path().join("project");
    std::fs::create_dir_all(&project_dir).unwrap();
    write_project(&project_dir, "tax = subtotal * TAX");

    let storage = Arc::new(Storage::open_in_memory().unwrap());
    let sink = Arc::new(RecordingSink::new());
    let manager = ExecutionManager::new(storage.clone(), sink.clone(), dir.path().to_path_buf());

    let started = manager
        .start(build_spec(&project_dir, tracer, python, None, 15_000))
        .expect("run should start");
    assert_eq!(started.status, "running");

    let session = wait_for_finish(&storage, &started.id);
    assert_eq!(session.status, "ok", "error: {:?}", session.error);
    assert_eq!(session.exit_code, Some(0));
    assert!(session.duration_ms.unwrap_or(0) >= 0);
    assert!(session.trace_event_count > 10);
    assert!(session.peak_memory_bytes.unwrap_or(0) > 0);

    let output = storage.session_output(&session.id).unwrap();
    assert!(output.stdout.contains("total=220.0"), "stdout was {:?}", output.stdout);

    let history = storage
        .variable_history(&session.id, "total", 50)
        .unwrap();
    assert!(!history.is_empty(), "total should have a recorded history");
    assert_eq!(history.last().unwrap().value.as_deref(), Some("220.0"));

    let snapshots = storage.variables_at(&session.id, None).unwrap();
    assert!(snapshots.iter().any(|snapshot| snapshot.name == "subtotal"));

    let events = sink.names();
    assert!(events.iter().any(|name| name == "run:output"));
    assert!(events.iter().any(|name| name == "run:trace"));
    assert!(events.iter().any(|name| name == "run:finished"));
    assert!(!manager.is_running(&session.id));
}

#[tokio::test(flavor = "multi_thread")]
async fn runs_without_instrumentation_when_tracing_is_disabled() {
    let (_tracer, python) = tracer_and_python();
    let dir = tempdir().unwrap();
    let project_dir = dir.path().join("project");
    std::fs::create_dir_all(&project_dir).unwrap();
    write_project(&project_dir, "tax = subtotal * TAX");

    let storage = Arc::new(Storage::open_in_memory().unwrap());
    let sink = Arc::new(RecordingSink::new());
    let manager = ExecutionManager::new(storage.clone(), sink, dir.path().to_path_buf());

    let mut spec = build_spec(&project_dir, PathBuf::from("/definitely/missing/tracer.py"), python, None, 15_000);
    spec.trace_enabled = false;
    let started = manager.start(spec).expect("untraced run should start");
    let session = wait_for_finish(&storage, &started.id);

    assert_eq!(session.status, "ok");
    assert_eq!(session.trace_event_count, 0);
    assert!(storage
        .session_output(&session.id)
        .unwrap()
        .stdout
        .contains("total=220.0"));
}

#[tokio::test(flavor = "multi_thread")]
async fn enforces_timeouts_and_reports_them() {
    let (tracer, python) = tracer_and_python();
    let dir = tempdir().unwrap();
    let project_dir = dir.path().join("project");
    std::fs::create_dir_all(&project_dir).unwrap();
    std::fs::write(
        project_dir.join("main.py"),
        "while True:\n    pass\n",
    )
    .unwrap();

    let storage = Arc::new(Storage::open_in_memory().unwrap());
    let sink = Arc::new(RecordingSink::new());
    let manager = ExecutionManager::new(storage.clone(), sink, dir.path().to_path_buf());
    let started = manager
        .start(build_spec(&project_dir, tracer, python, None, 1_500))
        .unwrap();

    let session = wait_for_finish(&storage, &started.id);
    assert_eq!(session.status, "timeout");
    assert!(session.error.unwrap_or_default().contains("timeout"));
    assert!(session.duration_ms.unwrap_or(0) < 15_000);
}

#[tokio::test(flavor = "multi_thread")]
async fn cancellation_is_reported_as_cancelled() {
    let (tracer, python) = tracer_and_python();
    let dir = tempdir().unwrap();
    let project_dir = dir.path().join("project");
    std::fs::create_dir_all(&project_dir).unwrap();
    std::fs::write(
        project_dir.join("main.py"),
        "import time\nwhile True:\n    time.sleep(0.05)\n",
    )
    .unwrap();

    let storage = Arc::new(Storage::open_in_memory().unwrap());
    let sink = Arc::new(RecordingSink::new());
    let manager = ExecutionManager::new(storage.clone(), sink, dir.path().to_path_buf());
    let started = manager
        .start(build_spec(&project_dir, tracer, python, None, 15_000))
        .unwrap();

    std::thread::sleep(Duration::from_millis(600));
    manager.cancel(&started.id).expect("cancel should be accepted");

    let session = wait_for_finish(&storage, &started.id);
    assert_eq!(session.status, "cancelled");
    assert!(session
        .error
        .unwrap_or_default()
        .to_lowercase()
        .contains("cancel"));
}

#[tokio::test(flavor = "multi_thread")]
async fn experiments_replay_a_baseline_without_touching_the_original() {
    let (tracer, python) = tracer_and_python();
    let dir = tempdir().unwrap();
    let original = dir.path().join("original");
    std::fs::create_dir_all(&original).unwrap();
    write_project(&original, "tax = subtotal * TAX");

    let storage = Arc::new(Storage::open_in_memory().unwrap());
    let sink = Arc::new(RecordingSink::new());
    let data_dir = dir.path().join("data");
    std::fs::create_dir_all(&data_dir).unwrap();
    let manager = ExecutionManager::new(storage.clone(), sink, data_dir.clone());

    let project = project::open_project(&storage, &original).unwrap();
    assert_eq!(project.entry_point.as_deref(), Some("main.py"));

    let mut spec = build_spec(&original, tracer.clone(), python.clone(), None, 15_000);
    spec.project_id = project.id.clone();
    let baseline_started = manager.start(spec).unwrap();
    let baseline = wait_for_finish(&storage, &baseline_started.id);
    assert_eq!(baseline.status, "ok");

    let experiment = experiments::create_experiment(
        &storage,
        &data_dir,
        &project,
        &baseline,
        "Fixed tax base",
        Some("Tax should use the discounted subtotal".into()),
        &python,
        &tracer,
    )
    .unwrap();

    let original_source = std::fs::read_to_string(original.join("pricing.py")).unwrap();
    assert!(original_source.contains("tax = subtotal * TAX"));

    // Edit only the copy.
    let copy_path = Path::new(&experiment.path).join("pricing.py");
    let copy_source = std::fs::read_to_string(&copy_path).unwrap();
    std::fs::write(
        &copy_path,
        copy_source.replace("tax = subtotal * TAX", "tax = subtotal * TAX * 0.5"),
    )
    .unwrap();

    // The original must be byte-for-byte unchanged.
    assert_eq!(
        std::fs::read_to_string(original.join("pricing.py")).unwrap(),
        original_source
    );

    let mut experiment_spec = build_spec(
        Path::new(&experiment.path),
        tracer,
        python,
        None,
        15_000,
    );
    experiment_spec.project_id = project.id.clone();
    experiment_spec.experiment_id = Some(experiment.id.clone());
    experiment_spec.label = Some(experiment.name.clone());
    let experiment_started = manager.start(experiment_spec).unwrap();
    let experiment_session = wait_for_finish(&storage, &experiment_started.id);
    assert_eq!(experiment_session.status, "ok");

    let baseline_output = storage.session_output(&baseline.id).unwrap();
    let experiment_output = storage
        .session_output(&experiment_session.id)
        .unwrap();
    assert!(baseline_output.stdout.contains("total=220.0"));
    assert!(experiment_output.stdout.contains("total=210.0"));

    let comparison =
        experiments::compare_sessions(&storage, &baseline, &experiment_session).unwrap();
    assert!(comparison.stdout_divergence.is_some());
    assert!(comparison
        .variables
        .iter()
        .any(|variable| variable.name == "total" && variable.status == "changed"));
    assert!(comparison.warnings.iter().any(|warning| warning.contains("Replay")));
    assert_eq!(comparison.baseline_metrics.exit_code, Some(0));
    assert_eq!(comparison.experiment_metrics.exit_code, Some(0));

    // Experiment history is preserved in the database.
    assert_eq!(storage.list_experiments(&project.id).unwrap().len(), 1);
    let all_runs = storage.list_sessions(&project.id, 20).unwrap();
    assert_eq!(all_runs.len(), 2);

    // Data flow is available for the traced variable.
    let flow = stateglass_lib::tracing::build_data_flow(&storage, &baseline, "total").unwrap();
    assert!(!flow.nodes.is_empty());
    assert!(!flow.assignment_sites.is_empty());

    // Timestamps exist for ordering.
    assert!(baseline.started_at <= now_ms());
}
