//! Stateglass backend entry point.
//!
//! Module layout:
//! * `project`     — importing folders, safe file access, sample project
//! * `execution`   — child process management, streaming, timeouts, resources
//! * `tracing`     — NDJSON trace ingestion and data-flow graph construction
//! * `experiments` — isolated project copies and execution comparison
//! * `storage`     — SQLite persistence for everything above
//! * `commands`    — Tauri IPC commands and events

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

use execution::{EventSink, ExecutionManager, TauriSink};
use std::path::PathBuf;
use std::sync::Arc;
use storage::Storage;
use tauri::Manager;
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

fn initial_project_from_args() -> Option<String> {
    std::env::args()
        .skip(1)
        .find(|argument| !argument.starts_with('-'))
        .and_then(|argument| {
            let path = std::fs::canonicalize(argument).ok()?;
            path.is_dir().then(|| path.to_string_lossy().to_string())
        })
}

fn init_logging() {
    use tracing_subscriber::EnvFilter;
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("warn,stateglass=info"));
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .try_init();
}

pub fn run() {
    init_logging();
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let data_dir = app.path().app_data_dir()?;
            let resource_dir = app.path().resource_dir().ok();
            let sink: Arc<dyn EventSink> = Arc::new(TauriSink::new(app.handle().clone()));
            let state = create_state(
                data_dir,
                sink,
                initial_project_from_args(),
                resource_dir.as_deref(),
            )?;
            app.manage(state);
            Ok(())
        })
        .on_window_event(|window, event| {
            if matches!(event, tauri::WindowEvent::Destroyed) {
                if let Some(state) = window.app_handle().try_state::<AppState>() {
                    state.executions.shutdown_all();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::bootstrap,
            commands::list_python_runtimes,
            commands::set_global_python_path,
            commands::list_projects,
            commands::open_project,
            commands::create_sample_project,
            commands::get_project,
            commands::update_project_config,
            commands::set_project_consent,
            commands::list_files,
            commands::read_file,
            commands::write_file,
            commands::analyze_workspace,
            commands::start_run,
            commands::cancel_run,
            commands::list_sessions,
            commands::get_session,
            commands::get_session_output,
            commands::list_trace_events,
            commands::trace_stats,
            commands::variables_at,
            commands::variable_history,
            commands::data_flow,
            commands::create_experiment,
            commands::list_experiments,
            commands::compare_sessions,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Stateglass");
}
