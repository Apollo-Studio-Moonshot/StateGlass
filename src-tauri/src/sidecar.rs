use crate::commands;
use crate::error::{AppError, AppResult};
use crate::AppState;
use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::Value;

pub const PROTOCOL_VERSION: u32 = 1;

fn param<T: DeserializeOwned>(params: &Value, name: &str) -> AppResult<T> {
    let value = params.get(name).cloned().unwrap_or(Value::Null);
    serde_json::from_value(value).map_err(AppError::from)
}

fn encode<T: Serialize>(result: AppResult<T>) -> AppResult<Value> {
    serde_json::to_value(result?).map_err(AppError::from)
}

pub fn dispatch(state: &AppState, method: &str, params: Value) -> AppResult<Value> {
    match method {
        "bootstrap" => encode(commands::bootstrap_core(state)),
        "list_python_runtimes" => {
            let project_id = param(&params, "projectId")?;
            encode(commands::list_python_runtimes_core(state, project_id))
        }
        "set_global_python_path" => {
            let path = param(&params, "path")?;
            encode(commands::set_global_python_path_core(state, path))
        }
        "list_projects" => encode(commands::list_projects_core(state)),
        "open_project" => {
            let path = param(&params, "path")?;
            encode(commands::open_project_core(state, path))
        }
        "create_sample_project" => encode(commands::create_sample_project_core(state)),
        "get_project" => {
            let project_id = param(&params, "projectId")?;
            encode(commands::get_project_core(state, project_id))
        }
        "update_project_config" => {
            let project_id = param(&params, "projectId")?;
            let config = param(&params, "config")?;
            encode(commands::update_project_config_core(
                state, project_id, config,
            ))
        }
        "set_project_consent" => {
            let project_id = param(&params, "projectId")?;
            let granted = param(&params, "granted")?;
            encode(commands::set_project_consent_core(
                state, project_id, granted,
            ))
        }
        "list_files" => {
            let project_id = param(&params, "projectId")?;
            let experiment_id = param(&params, "experimentId")?;
            encode(commands::list_files_core(state, project_id, experiment_id))
        }
        "read_file" => {
            let project_id = param(&params, "projectId")?;
            let experiment_id = param(&params, "experimentId")?;
            let path = param(&params, "path")?;
            encode(commands::read_file_core(
                state,
                project_id,
                experiment_id,
                path,
            ))
        }
        "write_file" => {
            let project_id = param(&params, "projectId")?;
            let experiment_id = param(&params, "experimentId")?;
            let path = param(&params, "path")?;
            let content = param(&params, "content")?;
            encode(commands::write_file_core(
                state,
                project_id,
                experiment_id,
                path,
                content,
            ))
        }
        "analyze_workspace" => {
            let project_id = param(&params, "projectId")?;
            let experiment_id = param(&params, "experimentId")?;
            encode(commands::analyze_workspace_core(
                state,
                project_id,
                experiment_id,
            ))
        }
        "start_run" => {
            let request = param(&params, "request")?;
            encode(commands::start_run_core(state, request))
        }
        "cancel_run" => {
            let session_id = param(&params, "sessionId")?;
            encode(commands::cancel_run_core(state, session_id))
        }
        "list_sessions" => {
            let project_id = param(&params, "projectId")?;
            let limit = param(&params, "limit")?;
            encode(commands::list_sessions_core(state, project_id, limit))
        }
        "get_session" => {
            let session_id = param(&params, "sessionId")?;
            encode(commands::get_session_core(state, session_id))
        }
        "get_session_output" => {
            let session_id = param(&params, "sessionId")?;
            encode(commands::get_session_output_core(state, session_id))
        }
        "list_trace_events" => {
            let session_id = param(&params, "sessionId")?;
            let kinds = param(&params, "kinds")?;
            let limit = param(&params, "limit")?;
            let offset = param(&params, "offset")?;
            let tail = param(&params, "tail")?;
            encode(commands::list_trace_events_core(
                state, session_id, kinds, limit, offset, tail,
            ))
        }
        "trace_stats" => {
            let session_id = param(&params, "sessionId")?;
            encode(commands::trace_stats_core(state, session_id))
        }
        "variables_at" => {
            let session_id = param(&params, "sessionId")?;
            let seq = param(&params, "seq")?;
            encode(commands::variables_at_core(state, session_id, seq))
        }
        "variable_history" => {
            let session_id = param(&params, "sessionId")?;
            let name = param(&params, "name")?;
            let limit = param(&params, "limit")?;
            encode(commands::variable_history_core(
                state, session_id, name, limit,
            ))
        }
        "data_flow" => {
            let session_id = param(&params, "sessionId")?;
            let variable = param(&params, "variable")?;
            encode(commands::data_flow_core(state, session_id, variable))
        }
        "create_experiment" => {
            let project_id = param(&params, "projectId")?;
            let baseline_session_id = param(&params, "baselineSessionId")?;
            let name = param(&params, "name")?;
            let note = param(&params, "note")?;
            encode(commands::create_experiment_core(
                state,
                project_id,
                baseline_session_id,
                name,
                note,
            ))
        }
        "list_experiments" => {
            let project_id = param(&params, "projectId")?;
            encode(commands::list_experiments_core(state, project_id))
        }
        "compare_sessions" => {
            let baseline_session_id = param(&params, "baselineSessionId")?;
            let experiment_session_id = param(&params, "experimentSessionId")?;
            encode(commands::compare_sessions_core(
                state,
                baseline_session_id,
                experiment_session_id,
            ))
        }
        _ => Err(AppError::validation(format!(
            "Unknown sidecar method: {method}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::execution::EventSink;
    use serde_json::json;
    use std::sync::Arc;

    struct NullSink;

    impl EventSink for NullSink {
        fn emit(&self, _: &str, _: Value) {}
    }

    #[test]
    fn dispatches_bootstrap_and_lists_projects() {
        let directory = tempfile::tempdir().unwrap();
        let state = crate::create_state(
            directory.path().to_path_buf(),
            Arc::new(NullSink),
            None,
            None,
        )
        .unwrap();

        let bootstrap = dispatch(&state, "bootstrap", json!({})).unwrap();
        assert_eq!(bootstrap["platform"], std::env::consts::OS);
        assert_eq!(bootstrap["tracerAvailable"], true);

        let projects = dispatch(&state, "list_projects", json!({})).unwrap();
        assert_eq!(projects, json!([]));
    }

    #[test]
    fn rejects_unknown_methods() {
        let directory = tempfile::tempdir().unwrap();
        let state = crate::create_state(
            directory.path().to_path_buf(),
            Arc::new(NullSink),
            None,
            None,
        )
        .unwrap();

        let error = dispatch(&state, "not_a_command", json!({})).unwrap_err();
        assert_eq!(error.kind(), "validation");
    }
}
