//! Experiment copies and side-by-side comparison of execution sessions.
//!
//! Experiments are *copies*. Nothing in this module writes to the imported
//! project directory; the copy is created under the app data directory and is
//! itself what gets edited and executed.

use crate::error::{AppError, AppResult};
use crate::models::*;
use crate::project::is_ignored;
use crate::storage::Storage;
use serde_json::json;
use similar::{ChangeTag, TextDiff};
use std::collections::BTreeMap;
use std::path::Path;
use walkdir::WalkDir;

const MAX_COPIED_FILES: usize = 30_000;
const MAX_COPIED_FILE_BYTES: u64 = 40_000_000;
const MAX_DIFF_LINES: usize = 2_500;

/// Recursively copy a project into an experiment directory.
pub fn copy_project(source: &Path, destination: &Path) -> AppResult<ExperimentCopyStats> {
    std::fs::create_dir_all(destination)?;
    let mut files = 0usize;
    let mut bytes = 0u64;
    for entry in WalkDir::new(source)
        .max_depth(24)
        .follow_links(false)
        .sort_by_file_name()
        .into_iter()
        .filter_entry(|entry| entry.depth() == 0 || !is_ignored(entry.path()))
        .flatten()
    {
        let path = entry.path();
        let relative = match path.strip_prefix(source) {
            Ok(relative) if !relative.as_os_str().is_empty() => relative.to_path_buf(),
            _ => continue,
        };
        let target = destination.join(&relative);
        if entry.file_type().is_dir() {
            std::fs::create_dir_all(&target)?;
            continue;
        }
        if !entry.file_type().is_file() {
            continue;
        }
        let size = entry.metadata().map(|meta| meta.len()).unwrap_or(0);
        if size > MAX_COPIED_FILE_BYTES {
            tracing::warn!(
                path = %path.display(),
                size,
                "Skipping oversized file while creating an experiment copy"
            );
            continue;
        }
        if files >= MAX_COPIED_FILES {
            return Err(AppError::validation(
                "This project has too many files to copy into an experiment safely",
            ));
        }
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::copy(path, &target)?;
        files += 1;
        bytes += size;
    }
    Ok(ExperimentCopyStats { files, bytes })
}

/// Create an isolated copy of the project and register it as an experiment.
pub fn create_experiment(
    storage: &Storage,
    data_dir: &Path,
    project: &Project,
    baseline: &Session,
    name: &str,
    note: Option<String>,
    python: &str,
    tracer: &Path,
) -> AppResult<Experiment> {
    if baseline.project_id != project.id {
        return Err(AppError::validation(
            "The selected baseline belongs to a different project",
        ));
    }
    if baseline.kind != "baseline" {
        return Err(AppError::validation(
            "Experiments must be created from a baseline execution",
        ));
    }
    if baseline.status == "running" {
        return Err(AppError::validation(
            "Wait for the baseline execution to finish before creating an experiment",
        ));
    }

    let id = new_id();
    let experiment_dir = data_dir.join("experiments").join(&id);
    let project_dir = experiment_dir.join("project");
    if experiment_dir.exists() {
        return Err(AppError::message(
            "An experiment directory with this identifier already exists",
        ));
    }
    let stats = copy_project(Path::new(&project.root_path), &project_dir)?;
    if stats.files == 0 {
        return Err(AppError::validation(
            "The project has no readable files to copy into an experiment",
        ));
    }

    let created_at = now_ms();
    let trimmed_name = if name.trim().is_empty() {
        "Untitled experiment".to_string()
    } else {
        name.trim().to_string()
    };
    let experiment = Experiment {
        id: id.clone(),
        project_id: project.id.clone(),
        baseline_session_id: baseline.id.clone(),
        name: trimmed_name,
        note,
        path: project_dir.to_string_lossy().to_string(),
        created_at,
        updated_at: created_at,
    };

    let metadata = json!({
        "id": experiment.id,
        "projectId": experiment.project_id,
        "projectName": project.name,
        "baselineSessionId": experiment.baseline_session_id,
        "name": experiment.name,
        "note": experiment.note,
        "createdAt": experiment.created_at,
        "sourceRoot": project.root_path,
        "filesCopied": stats.files,
    });
    std::fs::write(
        experiment_dir.join("experiment.json"),
        serde_json::to_vec_pretty(&metadata)?,
    )?;

    storage.insert_experiment(&experiment)?;

    // Best-effort static analysis of the copy. A failure here degrades the
    // data-flow graph but must not invalidate the experiment.
    if let Err(error) = crate::python::analyze_workspace(
        python,
        tracer,
        &project_dir,
        &experiment.id,
        storage,
    ) {
        tracing::warn!(error = %error, "Static analysis of experiment copy failed");
    }

    Ok(experiment)
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

fn noisy(name: &str, vtype: &str) -> bool {
    if name == "self" {
        return true;
    }
    matches!(
        vtype,
        "module"
            | "function"
            | "builtin_function_or_method"
            | "method"
            | "type"
            | "classmethod"
            | "staticmethod"
            | "wrapper_descriptor"
    )
}

fn metrics(session: &Session) -> RunMetrics {
    RunMetrics {
        duration_ms: session.duration_ms,
        peak_memory_bytes: session.peak_memory_bytes,
        exit_code: session.exit_code,
        status: session.status.clone(),
        trace_event_count: session.trace_event_count,
        stdout_bytes: session.stdout_bytes,
        stderr_bytes: session.stderr_bytes,
    }
}

fn diff_lines(baseline: &str, experiment: &str) -> (Vec<DiffLine>, bool) {
    let diff = TextDiff::from_lines(baseline, experiment);
    let mut lines = Vec::new();
    let mut truncated = false;
    for change in diff.iter_all_changes() {
        if lines.len() >= MAX_DIFF_LINES {
            truncated = true;
            break;
        }
        let kind = match change.tag() {
            ChangeTag::Equal => "same",
            ChangeTag::Delete => "remove",
            ChangeTag::Insert => "add",
        };
        lines.push(DiffLine {
            kind: kind.to_string(),
            baseline_line: change.old_index().map(|index| index + 1),
            experiment_line: change.new_index().map(|index| index + 1),
            text: change.to_string().trim_end_matches('\n').to_string(),
        });
    }
    (lines, truncated)
}

/// Compare a baseline session with an experiment session.
pub fn compare_sessions(
    storage: &Storage,
    baseline: &Session,
    experiment: &Session,
) -> AppResult<SessionComparison> {
    if baseline.id == experiment.id {
        return Err(AppError::validation(
            "Choose two different executions to compare",
        ));
    }
    if baseline.project_id != experiment.project_id {
        return Err(AppError::validation(
            "Both executions must belong to the same project",
        ));
    }
    if baseline.kind != "baseline" {
        return Err(AppError::validation(
            "The first execution must be a baseline run",
        ));
    }
    if experiment.kind != "experiment" {
        return Err(AppError::validation(
            "The second execution must come from an experiment copy",
        ));
    }
    if baseline.status == "running" || experiment.status == "running" {
        return Err(AppError::validation(
            "Wait for both executions to finish before comparing them",
        ));
    }
    let baseline_output = storage.session_output(&baseline.id)?;
    let experiment_output = storage.session_output(&experiment.id)?;
    let (stdout, stdout_truncated) = diff_lines(&baseline_output.stdout, &experiment_output.stdout);
    let (stderr, stderr_truncated) = diff_lines(&baseline_output.stderr, &experiment_output.stderr);

    let mut warnings: Vec<String> = vec![
        "Replay is not guaranteed to be identical: external services, databases, clocks, randomness, \
         filesystem state, and network access can make executions differ."
            .to_string(),
    ];

    if baseline.trace_truncated || experiment.trace_truncated {
        warnings.push(
            "At least one execution hit the trace event limit. Variable comparisons after that point are incomplete."
                .to_string(),
        );
    }
    if baseline.status != experiment.status {
        warnings.push(format!(
            "Execution status differs: baseline is “{}”, experiment is “{}”.",
            baseline.status, experiment.status
        ));
    }
    for (label, session) in [("Baseline", baseline), ("Experiment", experiment)] {
        if let Some(error) = &session.error {
            warnings.push(format!("{} ended with an error: {}", label, error));
        }
    }

    let baseline_vars: BTreeMap<String, (String, String)> = storage
        .final_variables(&baseline.id)?
        .into_iter()
        .filter(|(name, _value, vtype)| !noisy(name, vtype))
        .map(|(name, value, vtype)| (name, (value, vtype)))
        .collect();
    let experiment_vars: BTreeMap<String, (String, String)> = storage
        .final_variables(&experiment.id)?
        .into_iter()
        .filter(|(name, _value, vtype)| !noisy(name, vtype))
        .map(|(name, value, vtype)| (name, (value, vtype)))
        .collect();

    let mut names: Vec<&String> = baseline_vars
        .keys()
        .chain(experiment_vars.keys())
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect();
    names.sort();

    let mut variables = Vec::new();
    for name in names {
        let left = baseline_vars.get(name);
        let right = experiment_vars.get(name);
        let status = match (left, right) {
            (Some((left_value, left_type)), Some((right_value, right_type))) => {
                if left_value == right_value && left_type == right_type {
                    "same"
                } else {
                    "changed"
                }
            }
            (Some(_), None) => "removed",
            (None, Some(_)) => "added",
            (None, None) => continue,
        };
        variables.push(VariableDiff {
            name: name.to_string(),
            baseline_value: left.map(|(value, _)| value.clone()),
            baseline_type: left.map(|(_, vtype)| vtype.clone()),
            experiment_value: right.map(|(value, _)| value.clone()),
            experiment_type: right.map(|(_, vtype)| vtype.clone()),
            status: status.to_string(),
        });
    }

    let first_divergence = stdout
        .iter()
        .find(|line| line.kind != "same")
        .and_then(|line| line.baseline_line.or(line.experiment_line));

    if first_divergence.is_some() {
        warnings.push(format!(
            "Program output differs starting near line {}.",
            first_divergence.unwrap_or(0)
        ));
    }
    if baseline.exit_code != experiment.exit_code {
        warnings.push(format!(
            "Exit codes differ (baseline {:?}, experiment {:?}).",
            baseline.exit_code, experiment.exit_code
        ));
    }
    if stdout_truncated || stderr_truncated {
        warnings.push(format!(
            "The diff was capped at {} lines; open either session's full output for details.",
            MAX_DIFF_LINES
        ));
    }

    Ok(SessionComparison {
        baseline: baseline.clone(),
        experiment: experiment.clone(),
        baseline_metrics: metrics(baseline),
        experiment_metrics: metrics(experiment),
        stdout,
        stderr,
        variables,
        stdout_divergence: first_divergence,
        warnings,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn copying_never_touches_the_source() {
        let dir = tempdir().unwrap();
        let source = dir.path().join("source");
        fs::create_dir_all(source.join("pkg")).unwrap();
        fs::create_dir_all(source.join("__pycache__")).unwrap();
        fs::write(source.join("main.py"), "print('hi')\n").unwrap();
        fs::write(source.join("pkg/util.py"), "x = 1\n").unwrap();
        fs::write(source.join("__pycache__/main.pyc"), "junk").unwrap();

        let destination = dir.path().join("experiment");
        let stats = copy_project(&source, &destination).unwrap();
        assert_eq!(stats.files, 2);
        assert!(destination.join("main.py").is_file());
        assert!(destination.join("pkg/util.py").is_file());
        assert!(!destination.join("__pycache__/main.pyc").exists());

        fs::write(destination.join("main.py"), "print('changed')\n").unwrap();
        assert_eq!(
            fs::read_to_string(source.join("main.py")).unwrap(),
            "print('hi')\n"
        );
    }

    #[test]
    fn diff_marks_additions_and_removals() {
        let (lines, truncated) = diff_lines("a\nb\nc\n", "a\nB\nc\nd\n");
        assert!(!truncated);
        assert!(lines.iter().any(|line| line.kind == "remove" && line.text == "b"));
        assert!(lines.iter().any(|line| line.kind == "add" && line.text == "B"));
        assert!(lines.iter().any(|line| line.kind == "add" && line.text == "d"));
        let same = lines.iter().filter(|line| line.kind == "same").count();
        assert_eq!(same, 2);
    }

    #[test]
    fn comparison_reports_variable_and_output_changes() {
        let storage = Storage::open_in_memory().unwrap();
        let baseline = test_session("b", "baseline", "ok", Some(0), 100);
        let experiment = test_session("e", "experiment", "error", Some(1), 250);
        storage.insert_session(&baseline, "/tmp/b.ndjson").unwrap();
        storage.insert_session(&experiment, "/tmp/e.ndjson").unwrap();

        insert_var(&storage, &baseline.id, 1, "total", "10");
        insert_var(&storage, &experiment.id, 1, "total", "12");
        insert_var(&storage, &baseline.id, 2, "only_base", "1");
        insert_var(&storage, &experiment.id, 2, "only_exp", "2");

        storage
            .finish_session(
                &baseline.id,
                "ok",
                Some(0),
                10,
                100,
                Some(1000),
                None,
                "total=10\n",
                "",
                2,
                false,
            )
            .unwrap();
        storage
            .finish_session(
                &experiment.id,
                "error",
                Some(1),
                20,
                250,
                Some(2000),
                Some("Boom"),
                "total=12\n",
                "Traceback\n",
                2,
                false,
            )
            .unwrap();

        let baseline = storage.get_session(&baseline.id).unwrap();
        let experiment = storage.get_session(&experiment.id).unwrap();
        let comparison = compare_sessions(&storage, &baseline, &experiment).unwrap();

        assert!(comparison
            .variables
            .iter()
            .any(|entry| entry.name == "total" && entry.status == "changed"));
        assert!(comparison
            .variables
            .iter()
            .any(|entry| entry.name == "only_base" && entry.status == "removed"));
        assert!(comparison
            .variables
            .iter()
            .any(|entry| entry.name == "only_exp" && entry.status == "added"));
        assert_eq!(comparison.stdout_divergence, Some(1));
        assert!(comparison.warnings.iter().any(|warning| warning.contains("status differs")));
        assert!(comparison.warnings.iter().any(|warning| warning.contains("Replay")));
    }

    #[test]
    fn comparison_rejects_mismatched_sessions() {
        let storage = Storage::open_in_memory().unwrap();
        let baseline = test_session("b", "baseline", "ok", Some(0), 100);
        let experiment = test_session("e", "experiment", "ok", Some(0), 100);

        assert!(compare_sessions(&storage, &baseline, &baseline).is_err());
        // Roles are not interchangeable: the baseline must come first.
        assert!(compare_sessions(&storage, &experiment, &baseline).is_err());

        let mut other_project = experiment.clone();
        other_project.id = "e2".into();
        other_project.project_id = "p2".into();
        assert!(compare_sessions(&storage, &baseline, &other_project).is_err());

        let mut baseline_from_experiment = baseline.clone();
        baseline_from_experiment.kind = "experiment".into();
        assert!(compare_sessions(&storage, &baseline_from_experiment, &experiment).is_err());
    }

    fn test_session(
        id: &str,
        kind: &str,
        status: &str,
        code: Option<i32>,
        duration: i64,
    ) -> Session {
        Session {
            id: id.into(),
            project_id: "p1".into(),
            experiment_id: None,
            kind: kind.into(),
            label: None,
            command: "python3 main.py".into(),
            args: vec![],
            stdin: None,
            cwd: "/tmp/demo".into(),
            entry_file: Some("main.py".into()),
            python: "python3".into(),
            status: status.into(),
            exit_code: code,
            started_at: 0,
            finished_at: None,
            duration_ms: Some(duration),
            peak_memory_bytes: None,
            timeout_ms: 10_000,
            error: None,
            stdout_preview: String::new(),
            stderr_preview: String::new(),
            stdout_bytes: 0,
            stderr_bytes: 0,
            trace_event_count: 0,
            trace_truncated: false,
        }
    }

    fn insert_var(storage: &Storage, session_id: &str, seq: i64, name: &str, value: &str) {
        storage
            .insert_trace_batch(
                session_id,
                &[RawTraceEvent {
                    seq,
                    ts: seq,
                    kind: "var".into(),
                    name: Some(name.into()),
                    value: Some(value.into()),
                    vtype: Some("int".into()),
                    ..Default::default()
                }],
            )
            .unwrap();
    }
}
