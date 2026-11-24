//! Development utility that seeds a Stateglass database with a real baseline
//! run and a real experiment run for the bundled sample project.
//!
//! This is not part of the app. It exists so contributors (and documentation
//! screenshots) can reproduce a populated workspace without clicking through
//! the UI.
//!
//! ```sh
//! cargo run --example seed_demo -- ../../samples/python-demo "$HOME/Library/Application Support/dev.stateglass.app"
//! ```

use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use stateglass_lib::execution::{EventSink, ExecutionManager, RunSpec};
use stateglass_lib::models::{now_ms, Session};
use stateglass_lib::python::{analyze_workspace, find_tracer, resolve_python};
use stateglass_lib::storage::Storage;
use stateglass_lib::{experiments, project};

struct NullSink;
impl EventSink for NullSink {
    fn emit(&self, _event: &str, _payload: Value) {}
}

fn wait_for_finish(storage: &Storage, session_id: &str) -> Session {
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let session = storage.get_session(session_id).expect("session exists");
        if session.status != "running" {
            return session;
        }
        if Instant::now() > deadline {
            panic!("seed run did not finish");
        }
        std::thread::sleep(Duration::from_millis(120));
    }
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let project_dir = PathBuf::from(args.next().expect("usage: seed_demo <project> <data-dir>"));
    let data_dir = PathBuf::from(args.next().expect("usage: seed_demo <project> <data-dir>"));

    let storage = Arc::new(Storage::open(&data_dir.join("stateglass.sqlite3"))?);
    let (python, version) = resolve_python(Some(&project_dir), None, None)?;
    let tracer = find_tracer(None).expect("tracer exists");
    println!("python: {python} ({version:?})");

    let project = project::open_project(&storage, &project_dir)?;
    println!("project: {} ({})", project.name, project.id);
    storage.set_consent(&project.id, true)?;

    let analysis = analyze_workspace(
        &python,
        &tracer,
        Path::new(&project.root_path),
        &project.id,
        &storage,
    )?;
    println!(
        "analysis: {} files, {} assignments, {} issues",
        analysis.files,
        analysis.assignments,
        analysis.errors.len()
    );

    let manager = ExecutionManager::new(storage.clone(), Arc::new(NullSink), data_dir.clone());

    let baseline = manager.start(RunSpec {
        project_id: project.id.clone(),
        experiment_id: None,
        label: None,
        root: PathBuf::from(&project.root_path),
        python: python.clone(),
        tracer: tracer.clone(),
        entry: project.entry_point.clone().unwrap_or_else(|| "main.py".into()),
        args: vec![],
        stdin: None,
        timeout_ms: 20_000,
        trace_enabled: true,
    })?;
    let baseline = wait_for_finish(&storage, &baseline.id);
    println!(
        "baseline: {} events, {} ms, status {:?}",
        baseline.trace_event_count,
        baseline.duration_ms.unwrap_or(0),
        baseline.status
    );

    let experiment = experiments::create_experiment(
        &storage,
        &data_dir,
        &project,
        &baseline,
        "Fix tax base",
        Some("Compute tax from the discounted subtotal".into()),
        &python,
        &tracer,
    )?;

    let pricing_path = Path::new(&experiment.path).join("pricing.py");
    let source = std::fs::read_to_string(&pricing_path)?;
    let patched = source.replace(
        "tax = round(subtotal * TAX_RATE, 2)",
        "tax = round(discounted * TAX_RATE, 2)",
    );
    assert_ne!(patched, source, "expected to patch the intentional bug");
    std::fs::write(&pricing_path, patched)?;

    let experiment_run = manager.start(RunSpec {
        project_id: project.id.clone(),
        experiment_id: Some(experiment.id.clone()),
        label: Some(experiment.name.clone()),
        root: PathBuf::from(&experiment.path),
        python,
        tracer,
        entry: baseline.entry_file.clone().unwrap_or_else(|| "main.py".into()),
        args: baseline.args.clone(),
        stdin: None,
        timeout_ms: 20_000,
        trace_enabled: true,
    })?;
    let experiment_run = wait_for_finish(&storage, &experiment_run.id);
    println!(
        "experiment: {} events, {} ms, status {:?}",
        experiment_run.trace_event_count,
        experiment_run.duration_ms.unwrap_or(0),
        experiment_run.status
    );

    let comparison = experiments::compare_sessions(&storage, &baseline, &experiment_run)?;
    println!(
        "comparison: divergence at {:?}, {} changed variables",
        comparison.stdout_divergence,
        comparison
            .variables
            .iter()
            .filter(|variable| variable.status != "same")
            .count()
    );
    println!("seeded at {}", now_ms());
    Ok(())
}
