//! Python runtime discovery and integration with the instrumentation helper.
//!
//! Stateglass never imports Python code into the Rust process. It shells out to
//! a normal interpreter, which runs either the tracer (execution) or the AST
//! analyzer (static data-flow metadata).

use crate::error::{AppError, AppResult};
use crate::models::{AnalysisSummary, AssignmentRecord, PythonRuntime};
use crate::storage::Storage;
use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Locate `stateglass_tracer.py` in development or in a bundled application.
pub fn find_tracer(resource_dir: Option<&Path>) -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(explicit) = std::env::var("STATEGLASS_TRACER") {
        candidates.push(PathBuf::from(explicit));
    }
    if let Some(dir) = resource_dir {
        candidates.push(dir.join("python").join("stateglass_tracer.py"));
        candidates.push(dir.join("stateglass_tracer.py"));
    }
    candidates.push(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("python")
            .join("stateglass_tracer.py"),
    );
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            // macOS bundle layout: Contents/MacOS/app -> Contents/Resources/python
            candidates.push(
                parent
                    .join("..")
                    .join("Resources")
                    .join("python")
                    .join("stateglass_tracer.py"),
            );
            candidates.push(parent.join("python").join("stateglass_tracer.py"));
        }
    }
    candidates.push(PathBuf::from("python").join("stateglass_tracer.py"));
    candidates.into_iter().find(|path| path.is_file())
}

fn version_of(python: &str) -> Option<String> {
    let output = Command::new(python)
        .arg("--version")
        .output()
        .or_else(|_| Command::new(python).arg("-V").output())
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let text = if text.trim().is_empty() {
        String::from_utf8_lossy(&output.stderr).to_string()
    } else {
        text.to_string()
    };
    let version = text.split_whitespace().nth(1)?.to_string();
    Some(version)
}

pub fn supports_instrumentation(version: &str) -> bool {
    let mut parts = version.split('.');
    let major = parts.next().and_then(|part| part.parse::<u32>().ok());
    let minor = parts.next().and_then(|part| part.parse::<u32>().ok());
    match (major, minor) {
        (Some(major), Some(minor)) => major > 3 || (major == 3 && minor >= 11),
        _ => false,
    }
}

fn venv_candidates(root: &Path) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    for venv in [".venv", "venv", "env", ".env"] {
        let base = root.join(venv).join("bin");
        paths.push(base.join("python"));
        paths.push(base.join("python3"));
        if cfg!(windows) {
            let scripts = root.join(venv).join("Scripts");
            paths.push(scripts.join("python.exe"));
        }
    }
    paths
}

fn path_candidates() -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = ["python3.14", "python3.13", "python3.12", "python3.11", "python3", "python"]
        .iter()
        .map(PathBuf::from)
        .collect();
    if cfg!(windows) {
        paths.push(PathBuf::from("py"));
    }
    paths
}

/// Detect every usable interpreter for the current project (plus system ones).
pub fn detect_runtimes(project_root: Option<&Path>) -> Vec<PythonRuntime> {
    let mut runtimes: Vec<PythonRuntime> = Vec::new();
    let mut seen: Vec<PathBuf> = Vec::new();

    let mut push_runtime = |path: PathBuf, source: &str, runtimes: &mut Vec<PythonRuntime>| {
        let canonical = std::fs::canonicalize(&path).unwrap_or_else(|_| path.clone());
        if seen.contains(&canonical) {
            return;
        }
        if !canonical.exists() {
            return;
        }
        seen.push(canonical.clone());
        let version = version_of(&canonical.to_string_lossy());
        let supported = version
            .as_deref()
            .map(supports_instrumentation)
            .unwrap_or(false);
        runtimes.push(PythonRuntime {
            path: canonical.to_string_lossy().to_string(),
            version,
            source: source.to_string(),
            supported,
        });
    };

    if let Some(root) = project_root {
        for candidate in venv_candidates(root) {
            if candidate.is_file() {
                push_runtime(candidate, "project-venv", &mut runtimes);
            }
        }
    }
    for candidate in path_candidates() {
        if let Some(found) = which(&candidate) {
            push_runtime(found, "system", &mut runtimes);
        }
    }
    runtimes
}

fn which(candidate: &Path) -> Option<PathBuf> {
    if candidate.is_absolute() {
        return resolve_executable(candidate);
    }
    let path_var = std::env::var_os("PATH")?;
    for directory in std::env::split_paths(&path_var) {
        if let Some(full) = resolve_executable(&directory.join(candidate)) {
            return Some(full);
        }
    }
    None
}

/// Accept a plain path or, on Windows, try `PATHEXT` suffixes. This makes
/// extensionless candidates such as `python3` find `python3.exe`, and also
/// handles versioned names such as `python3.12`.
fn resolve_executable(path: &Path) -> Option<PathBuf> {
    if path.is_file() {
        return Some(path.to_path_buf());
    }
    if !cfg!(windows) {
        return None;
    }
    let extensions = std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_string());
    for extension in extensions.split(';') {
        let extension = extension.trim().trim_start_matches('.');
        if extension.is_empty() {
            continue;
        }
        let mut name = path.as_os_str().to_os_string();
        name.push(format!(".{}", extension));
        let candidate = PathBuf::from(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// Resolve the interpreter used for a run.
///
/// Precedence: explicit per-project override, explicit global override, a
/// project virtualenv, then the newest supported system interpreter.
pub fn resolve_python(
    project_root: Option<&Path>,
    project_override: Option<&str>,
    global_override: Option<&str>,
) -> AppResult<(String, Option<String>)> {
    for (value, label) in [
        (project_override, "project setting"),
        (global_override, "global setting"),
    ] {
        if let Some(value) = value.filter(|value| !value.trim().is_empty()) {
            let path = PathBuf::from(value);
            if !path.is_file() {
                return Err(AppError::validation(format!(
                    "Configured Python interpreter ({}) does not exist: {}",
                    label, value
                )));
            }
            let version = version_of(value);
            return Ok((value.to_string(), version));
        }
    }

    let runtimes = detect_runtimes(project_root);
    if let Some(runtime) = runtimes.iter().find(|runtime| runtime.supported) {
        return Ok((runtime.path.clone(), runtime.version.clone()));
    }
    if let Some(runtime) = runtimes
        .iter()
        .find(|runtime| runtime.source == "project-venv")
    {
        return Err(AppError::validation(format!(
            "The project virtualenv uses Python {}, but Stateglass requires Python 3.11 or newer",
            runtime.version.as_deref().unwrap_or("unknown")
        )));
    }
    Err(AppError::validation(
        "No Python 3.11+ interpreter was found. Install Python or configure an interpreter path in project settings.",
    ))
}

// ---------------------------------------------------------------------------
// AST analysis
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct AnalysisOutput {
    #[serde(default)]
    files: Vec<AnalyzedFile>,
}

#[derive(Debug, Deserialize)]
struct AnalyzedFile {
    file: String,
    #[serde(default)]
    assignments: Vec<AnalyzedAssignment>,
    #[serde(default)]
    errors: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct AnalyzedAssignment {
    line: i64,
    #[serde(default)]
    col: i64,
    func: String,
    target: String,
    #[serde(default)]
    sources: Vec<String>,
    callee: Option<String>,
    #[serde(default = "default_kind")]
    kind: String,
}

fn default_kind() -> String {
    "assign".to_string()
}

const MAX_ANALYZED_FILES: usize = 400;
const MAX_ANALYZED_BYTES: u64 = 512_000;
const ANALYSIS_BATCH: usize = 40;

/// Parse Python sources with the helper's AST analyzer and persist assignment
/// metadata used to build data-flow graphs.
pub fn analyze_workspace(
    python: &str,
    tracer: &Path,
    root: &Path,
    workspace_id: &str,
    storage: &Storage,
) -> AppResult<AnalysisSummary> {
    let files = crate::project::python_files(root, MAX_ANALYZED_FILES, MAX_ANALYZED_BYTES);
    if files.is_empty() {
        storage.replace_assignments(workspace_id, &[])?;
        return Ok(AnalysisSummary {
            files: 0,
            assignments: 0,
            errors: vec![],
        });
    }

    let mut all_records: Vec<AssignmentRecord> = Vec::new();
    let mut errors: Vec<String> = Vec::new();

    for chunk in files.chunks(ANALYSIS_BATCH) {
        let mut command = Command::new(python);
        command.arg(tracer).arg("analyze");
        for file in chunk {
            command.arg(file);
        }
        let output = command.output().map_err(|error| {
            AppError::execution(format!(
                "Could not run the Python analysis helper ({}): {}",
                python, error
            ))
        })?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            errors.push(format!(
                "Python analysis exited with {}: {}",
                output.status,
                stderr.trim().lines().last().unwrap_or("no output")
            ));
            continue;
        }
        let parsed: AnalysisOutput = match serde_json::from_slice(&output.stdout) {
            Ok(value) => value,
            Err(error) => {
                errors.push(format!("Could not parse analysis output: {}", error));
                continue;
            }
        };
        for file in parsed.files {
            for message in &file.errors {
                errors.push(format!("{}: {}", short_path(&file.file, root), message));
            }
            let relative = short_path(&file.file, root);
            for assignment in file.assignments {
                if assignment.target.len() > 200 || assignment.target.is_empty() {
                    continue;
                }
                all_records.push(AssignmentRecord {
                    file: relative.clone(),
                    line: assignment.line,
                    col: assignment.col,
                    func: assignment.func,
                    target: assignment.target,
                    sources: assignment.sources.into_iter().take(24).collect(),
                    callee: assignment.callee,
                    kind: assignment.kind,
                });
            }
        }
    }

    let count = all_records.len();
    storage.replace_assignments(workspace_id, &all_records)?;
    errors.truncate(20);
    Ok(AnalysisSummary {
        files: files.len(),
        assignments: count,
        errors,
    })
}

pub fn short_path(file: &str, root: &Path) -> String {
    let normalized = file.replace('\\', "/");
    let root_string = root.to_string_lossy().replace('\\', "/");
    let trimmed = normalized
        .strip_prefix(root_string.trim_end_matches('/'))
        // Only treat the prefix as a directory boundary; otherwise
        // "/work/demo2/a.py" would be reported as "2/a.py" for root "/work/demo".
        .filter(|rest| rest.is_empty() || rest.starts_with('/'))
        .unwrap_or(&normalized)
        .trim_start_matches('/')
        .to_string();
    if trimmed.is_empty() {
        normalized
    } else {
        trimmed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_supported_versions() {
        assert!(supports_instrumentation("3.11.0"));
        assert!(supports_instrumentation("3.13.2"));
        assert!(supports_instrumentation("4.0.0"));
        assert!(!supports_instrumentation("3.10.14"));
        assert!(!supports_instrumentation("2.7.18"));
        assert!(!supports_instrumentation("unknown"));
    }

    #[test]
    fn shortens_paths_relative_to_root() {
        assert_eq!(
            short_path("/work/demo/pkg/a.py", Path::new("/work/demo")),
            "pkg/a.py"
        );
        assert_eq!(
            short_path("C:\\work\\demo\\a.py", Path::new("C:/work/demo")),
            "a.py"
        );
        assert_eq!(short_path("/elsewhere/a.py", Path::new("/work/demo")), "elsewhere/a.py");
        assert_eq!(
            short_path("/work/demo2/a.py", Path::new("/work/demo")),
            "work/demo2/a.py"
        );
    }

    #[test]
    fn finds_the_bundled_tracer_in_development() {
        let tracer = find_tracer(None).expect("tracer should exist in the repository");
        assert!(tracer.ends_with("python/stateglass_tracer.py"));
    }
}
