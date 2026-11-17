//! Tauri IPC surface.
//!
//! Commands are deliberately thin: they validate/resolve inputs, delegate to
//! the domain modules, and map errors into the serializable `AppError` shape.
//! Streaming execution, trace and filesystem updates are delivered as events
//! (`run:output`, `run:trace`, `run:stats`, `run:finished`,
//! `workspace:changed`).

use crate::error::{AppError, AppResult};
use crate::execution::RunSpec;
use crate::models::*;
use crate::python;
use crate::storage::Storage;
use crate::tracing as trace_engine;
use crate::tracing::{TRACE_MAX_DEPTH, TRACE_MAX_EVENTS, TRACE_MAX_LOCALS, TRACE_VALUE_LENGTH};
use crate::{experiments, project, AppState};
use std::path::{Path, PathBuf};
use tauri::{AppHandle, State};

fn tracer_for(state: &AppState) -> AppResult<PathBuf> {
    state
        .tracer_path
        .clone()
        .filter(|path| path.is_file())
        .ok_or_else(|| {
            AppError::execution(
                "The Python instrumentation helper is missing. Reinstall Stateglass or set STATEGLASS_TRACER.",
            )
        })
}

fn global_python_override(storage: &Storage) -> AppResult<Option<String>> {
    storage.get_setting("python_path")
}

fn resolve_python_for(state: &AppState, project: &Project) -> AppResult<(String, Option<String>)> {
    let global = global_python_override(&state.storage)?;
    python::resolve_python(
        Some(Path::new(&project.root_path)),
        project.python_path.as_deref(),
        global.as_deref(),
    )
}

fn resolve_workspace(
    state: &AppState,
    project_id: &str,
    experiment_id: Option<&str>,
) -> AppResult<(Project, PathBuf, String)> {
    let project = state.storage.get_project(project_id)?;
    match experiment_id {
        Some(experiment_id) => {
            let experiment = state.storage.get_experiment(experiment_id)?;
            if experiment.project_id != project.id {
                return Err(AppError::validation(
                    "Experiment does not belong to this project",
                ));
            }
            let root = PathBuf::from(&experiment.path);
            if !root.is_dir() {
                return Err(AppError::message(
                    "This experiment's project copy is missing from disk",
                ));
            }
            Ok((project, root, experiment.id))
        }
        None => {
            let root = PathBuf::from(&project.root_path);
            if !root.is_dir() {
                return Err(AppError::message(
                    "The project folder is no longer available on disk",
                ));
            }
            let workspace_id = project.id.clone();
            Ok((project, root, workspace_id))
        }
    }
}

fn run_analysis(
    state: &AppState,
    project: &Project,
    root: &Path,
    workspace_id: &str,
) -> AppResult<AnalysisSummary> {
    let (python_path, _) = resolve_python_for(state, project)?;
    let tracer = tracer_for(state)?;
    python::analyze_workspace(&python_path, &tracer, root, workspace_id, &state.storage)
}

fn open_project_impl(app: &AppHandle, state: &AppState, path: &Path) -> AppResult<Project> {
    let project = project::open_project(&state.storage, path)?;
    if let Err(error) = state
        .watchers
        .watch(&project.id, Path::new(&project.root_path), app.clone())
    {
        tracing::warn!(%error, "Could not watch project files");
    }
    if let Err(error) = run_analysis(
        state,
        &project,
        Path::new(&project.root_path),
        &project.id,
    ) {
        tracing::warn!(%error, "Initial static analysis failed");
    }
    Ok(project)
}

// ---------------------------------------------------------------------------
// Bootstrap & environment
// ---------------------------------------------------------------------------

#[tauri::command]
pub fn bootstrap(state: State<'_, AppState>) -> AppResult<Bootstrap> {
    let selected_python = global_python_override(&state.storage)?;
    let tracer_path = state.tracer_path.clone();
    let tracer_available = tracer_path.as_ref().map(|path| path.is_file()).unwrap_or(false);
    Ok(Bootstrap {
        version: env!("CARGO_PKG_VERSION").to_string(),
        data_dir: state.data_dir.to_string_lossy().to_string(),
        platform: std::env::consts::OS.to_string(),
        python: python::detect_runtimes(None),
        selected_python,
        trace_limits: TraceLimits {
            max_events: TRACE_MAX_EVENTS,
            value_length: TRACE_VALUE_LENGTH,
            max_depth: TRACE_MAX_DEPTH,
            max_locals: TRACE_MAX_LOCALS,
        },
        tracer_path: tracer_path
            .map(|path| path.to_string_lossy().to_string())
            .unwrap_or_default(),
        tracer_available,
        initial_project_path: state.initial_project.clone(),
    })
}

#[tauri::command]
pub fn list_python_runtimes(
    state: State<'_, AppState>,
    project_id: Option<String>,
) -> AppResult<Vec<PythonRuntime>> {
    let root = match project_id {
        Some(project_id) => Some(PathBuf::from(
            state.storage.get_project(&project_id)?.root_path,
        )),
        None => None,
    };
    Ok(python::detect_runtimes(root.as_deref()))
}

#[tauri::command]
pub fn set_global_python_path(state: State<'_, AppState>, path: Option<String>) -> AppResult<()> {
    match path.filter(|value| !value.trim().is_empty()) {
        Some(path) => state.storage.set_setting("python_path", path.trim())?,
        None => state.storage.set_setting("python_path", "")?,
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Projects & files
// ---------------------------------------------------------------------------

#[tauri::command]
pub fn list_projects(state: State<'_, AppState>) -> AppResult<Vec<Project>> {
    state.storage.list_projects(30)
}

#[tauri::command]
pub fn open_project(
    app: AppHandle,
    state: State<'_, AppState>,
    path: String,
) -> AppResult<Project> {
    open_project_impl(&app, &state, Path::new(&path))
}

#[tauri::command]
pub fn create_sample_project(
    app: AppHandle,
    state: State<'_, AppState>,
) -> AppResult<Project> {
    let directory = state.data_dir.join("samples").join("python-demo");
    project::create_sample_project(&directory)?;
    open_project_impl(&app, &state, &directory)
}

#[tauri::command]
pub fn get_project(state: State<'_, AppState>, project_id: String) -> AppResult<Project> {
    state.storage.get_project(&project_id)
}

#[tauri::command]
pub fn update_project_config(
    state: State<'_, AppState>,
    project_id: String,
    config: ProjectConfigInput,
) -> AppResult<Project> {
    if let Some(entry) = config.entry_point.as_deref().filter(|value| !value.is_empty()) {
        let project = state.storage.get_project(&project_id)?;
        project::resolve_inside(Path::new(&project.root_path), entry)?;
    }
    state
        .storage
        .update_project_config(&project_id, &config)
}

#[tauri::command]
pub fn set_project_consent(
    state: State<'_, AppState>,
    project_id: String,
    granted: bool,
) -> AppResult<Project> {
    state.storage.set_consent(&project_id, granted)
}

#[tauri::command]
pub fn list_files(
    state: State<'_, AppState>,
    project_id: String,
    experiment_id: Option<String>,
) -> AppResult<Vec<FileEntry>> {
    let (_project, root, _workspace) =
        resolve_workspace(&state, &project_id, experiment_id.as_deref())?;
    project::list_files(&root)
}

#[tauri::command]
pub fn read_file(
    state: State<'_, AppState>,
    project_id: String,
    experiment_id: Option<String>,
    path: String,
) -> AppResult<FileContent> {
    let (_project, root, _workspace) =
        resolve_workspace(&state, &project_id, experiment_id.as_deref())?;
    project::read_text(&root, &path)
}

#[tauri::command]
pub fn write_file(
    state: State<'_, AppState>,
    project_id: String,
    experiment_id: Option<String>,
    path: String,
    content: String,
) -> AppResult<FileContent> {
    let (_project, root, _workspace) =
        resolve_workspace(&state, &project_id, experiment_id.as_deref())?;
    project::write_text(&root, &path, &content)
}

#[tauri::command]
pub fn analyze_workspace(
    state: State<'_, AppState>,
    project_id: String,
    experiment_id: Option<String>,
) -> AppResult<AnalysisSummary> {
    let (project, root, workspace_id) =
        resolve_workspace(&state, &project_id, experiment_id.as_deref())?;
    run_analysis(&state, &project, &root, &workspace_id)
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

#[tauri::command]
pub fn start_run(state: State<'_, AppState>, request: RunRequest) -> AppResult<Session> {
    let project = state.storage.get_project(&request.project_id)?;
    if !project.consent_granted {
        return Err(AppError::ConsentRequired(
            "Running project code requires your consent. Stateglass executes code with your user privileges and is not a security sandbox.".to_string(),
        ));
    }

    let experiment = match request.experiment_id.as_deref() {
        Some(experiment_id) => {
            let experiment = state.storage.get_experiment(experiment_id)?;
            if experiment.project_id != project.id {
                return Err(AppError::validation(
                    "Experiment does not belong to this project",
                ));
            }
            Some(experiment)
        }
        None => None,
    };

    let (root, entry, args, stdin, timeout_ms, python_path, label) = match &experiment {
        Some(experiment) => {
            let baseline_id = request
                .baseline_session_id
                .clone()
                .or_else(|| Some(experiment.baseline_session_id.clone()))
                .unwrap_or_default();
            if baseline_id.is_empty() {
                return Err(AppError::validation(
                    "Select a baseline execution to replay in this experiment",
                ));
            }
            let baseline = state.storage.get_session(&baseline_id)?;
            if baseline.project_id != project.id {
                return Err(AppError::validation(
                    "The baseline session belongs to a different project",
                ));
            }
            if baseline.kind != "baseline" {
                return Err(AppError::validation(
                    "Experiments replay baseline executions, not other experiments",
                ));
            }
            if baseline.status == "running" {
                return Err(AppError::validation(
                    "The baseline execution is still running",
                ));
            }
            let entry = baseline
                .entry_file
                .clone()
                .or_else(|| project.entry_point.clone())
                .ok_or_else(|| {
                    AppError::validation("The baseline has no recorded entry point")
                })?;
            let python = if Path::new(&baseline.python).is_file() {
                baseline.python.clone()
            } else {
                resolve_python_for(&state, &project)?.0
            };
            (
                PathBuf::from(&experiment.path),
                entry,
                baseline.args.clone(),
                request.stdin.clone().or_else(|| baseline.stdin.clone()),
                baseline.timeout_ms as u64,
                python,
                Some(experiment.name.clone()),
            )
        }
        None => {
            let root = PathBuf::from(&project.root_path);
            let entry = project
                .entry_point
                .clone()
                .or_else(|| project::detect_entry(&root))
                .ok_or_else(|| {
                    AppError::validation(
                        "No Python entry point is configured. Choose an entry file in the run settings.",
                    )
                })?;
            let (python_path, _) = resolve_python_for(&state, &project)?;
            (
                root,
                entry,
                project.run_args.clone(),
                request.stdin.clone(),
                project.timeout_ms,
                python_path,
                None,
            )
        }
    };

    let trace_enabled = project.tracing || experiment.is_some();
    let tracer = if trace_enabled {
        tracer_for(&state)?
    } else {
        state.tracer_path.clone().unwrap_or_default()
    };
    let spec = RunSpec {
        project_id: project.id.clone(),
        experiment_id: experiment.as_ref().map(|value| value.id.clone()),
        label,
        root,
        python: python_path,
        tracer,
        entry,
        args,
        stdin,
        timeout_ms,
        trace_enabled,
    };

    state.executions.start(spec)
}

#[tauri::command]
pub fn cancel_run(state: State<'_, AppState>, session_id: String) -> AppResult<()> {
    state.executions.cancel(&session_id)
}

#[tauri::command]
pub fn list_sessions(
    state: State<'_, AppState>,
    project_id: String,
    limit: Option<u32>,
) -> AppResult<Vec<Session>> {
    state
        .storage
        .list_sessions(&project_id, limit.unwrap_or(80).clamp(1, 500))
}

#[tauri::command]
pub fn get_session(state: State<'_, AppState>, session_id: String) -> AppResult<Session> {
    state.storage.get_session(&session_id)
}

#[tauri::command]
pub fn get_session_output(
    state: State<'_, AppState>,
    session_id: String,
) -> AppResult<SessionOutput> {
    state.storage.session_output(&session_id)
}

// ---------------------------------------------------------------------------
// Tracing
// ---------------------------------------------------------------------------

#[tauri::command]
pub fn list_trace_events(
    state: State<'_, AppState>,
    session_id: String,
    kinds: Option<Vec<String>>,
    limit: Option<u32>,
    offset: Option<u32>,
    tail: Option<bool>,
) -> AppResult<TracePage> {
    state.storage.list_trace_events(
        &session_id,
        kinds.as_deref().unwrap_or(&[]),
        limit.unwrap_or(4_000),
        offset.unwrap_or(0),
        tail.unwrap_or(false),
    )
}

#[tauri::command]
pub fn trace_stats(state: State<'_, AppState>, session_id: String) -> AppResult<TraceStats> {
    state.storage.trace_stats(&session_id)
}

#[tauri::command]
pub fn variables_at(
    state: State<'_, AppState>,
    session_id: String,
    seq: Option<i64>,
) -> AppResult<Vec<VariableSnapshot>> {
    state.storage.variables_at(&session_id, seq)
}

#[tauri::command]
pub fn variable_history(
    state: State<'_, AppState>,
    session_id: String,
    name: String,
    limit: Option<u32>,
) -> AppResult<Vec<TraceEvent>> {
    state
        .storage
        .variable_history(&session_id, &name, limit.unwrap_or(300).clamp(1, 2000))
}

#[tauri::command]
pub fn data_flow(
    state: State<'_, AppState>,
    session_id: String,
    variable: String,
) -> AppResult<DataFlow> {
    let session = state.storage.get_session(&session_id)?;
    trace_engine::build_data_flow(&state.storage, &session, &variable)
}

// ---------------------------------------------------------------------------
// Experiments & comparison
// ---------------------------------------------------------------------------

#[tauri::command]
pub fn create_experiment(
    app: AppHandle,
    state: State<'_, AppState>,
    project_id: String,
    baseline_session_id: String,
    name: String,
    note: Option<String>,
) -> AppResult<Experiment> {
    let project = state.storage.get_project(&project_id)?;
    let baseline = state.storage.get_session(&baseline_session_id)?;
    let (python_path, _) = resolve_python_for(&state, &project)?;
    let tracer = tracer_for(&state)?;
    let experiment = experiments::create_experiment(
        &state.storage,
        &state.data_dir,
        &project,
        &baseline,
        &name,
        note,
        &python_path,
        &tracer,
    )?;
    if let Err(error) = state.watchers.watch(
        &experiment.id,
        Path::new(&experiment.path),
        app.clone(),
    ) {
        tracing::warn!(%error, "Could not watch experiment files");
    }
    Ok(experiment)
}

#[tauri::command]
pub fn list_experiments(
    state: State<'_, AppState>,
    project_id: String,
) -> AppResult<Vec<Experiment>> {
    state.storage.list_experiments(&project_id)
}

#[tauri::command]
pub fn compare_sessions(
    state: State<'_, AppState>,
    baseline_session_id: String,
    experiment_session_id: String,
) -> AppResult<SessionComparison> {
    if baseline_session_id == experiment_session_id {
        return Err(AppError::validation(
            "Choose two different executions to compare",
        ));
    }
    let baseline = state.storage.get_session(&baseline_session_id)?;
    let experiment = state.storage.get_session(&experiment_session_id)?;
    experiments::compare_sessions(&state.storage, &baseline, &experiment)
}
