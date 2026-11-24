//! Stateglass backend entry point.
//!
//! Module layout:
//! * `project`     — importing folders, safe file access, sample project
//! * `execution`   — child process management, streaming, timeouts, resources
//! * `tracing`     — NDJSON trace ingestion and data-flow graph construction
//! * `experiments` — isolated project copies and execution comparison
//! * `storage`     — SQLite persistence for everything above
//! * `commands`    — request handlers shared by the sidecar

pub mod commands;
pub mod error;
pub mod execution;
pub mod experiments;
pub mod models;
pub mod project;
pub mod python;
pub mod sidecar;
pub mod storage;
pub mod tracing;
pub mod watchers;

use execution::{EventSink, ExecutionManager};
use std::path::PathBuf;
use std::sync::Arc;
use storage::Storage;
use watchers::WatchManager;

pub struct AppState {
    pub storage: Arc<Storage>,
    pub data_dir: PathBuf,
    pub executions: Arc<ExecutionManager>,
    pub watchers: Arc<WatchManager>,
    pub tracer_path: Option<PathBuf>,
    pub initial_project: Option<String>,
}

pub fn create_state(
    data_dir: PathBuf,
    sink: Arc<dyn EventSink>,
    initial_project: Option<String>,
    resource_dir: Option<&std::path::Path>,
) -> Result<AppState, error::AppError> {
    std::fs::create_dir_all(&data_dir)?;
    let storage = Arc::new(Storage::open(&data_dir.join("stateglass.sqlite3"))?);
    if let Err(error) = storage.reconcile_running_sessions() {
        ::tracing::warn!(%error, "Could not reconcile stale running sessions");
    }

    let tracer_path = python::find_tracer(resource_dir);
    if tracer_path.is_none() {
        ::tracing::error!(
            "Python instrumentation helper was not found; execution tracing will be unavailable"
        );
    }

    let executions = Arc::new(ExecutionManager::new(
        storage.clone(),
        sink.clone(),
        data_dir.clone(),
    ));
    let watchers = Arc::new(WatchManager::new(sink));
    Ok(AppState {
        storage,
        data_dir,
        executions,
        watchers,
        tracer_path,
        initial_project,
    })
}

pub fn init_logging() {
    use tracing_subscriber::EnvFilter;
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("warn,stateglass=info"));
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .try_init();
}
