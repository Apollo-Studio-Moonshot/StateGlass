//! Local project management: importing folders, file browsing, safe file
//! access, and sample project creation.
//!
//! The original project directory is only ever read. Experimental copies live
//! under the application data directory and are managed by `experiments`.

use crate::error::{AppError, AppResult};
use crate::models::{now_ms, new_id, FileContent, FileEntry, Project};
use crate::storage::Storage;
use std::path::{Component, Path, PathBuf};
use walkdir::WalkDir;

pub const IGNORED_DIRS: &[&str] = &[
    ".git",
    ".hg",
    ".svn",
    ".idea",
    ".vscode",
    "__pycache__",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".tox",
    ".venv",
    "venv",
    "env",
    ".env",
    "node_modules",
    "site-packages",
    "dist",
    "dist-packages",
    "build",
    "target",
    ".next",
    ".cache",
    ".stateglass",
];

const MAX_LISTED_FILES: usize = 8_000;
const MAX_FILE_BYTES: u64 = 3_000_000;
const MAX_TREE_DEPTH: usize = 14;

pub fn is_ignored(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .map(|name| {
            if name == ".env" {
                return false;
            }
            IGNORED_DIRS.contains(&name) || (name.starts_with('.') && name != "." && name != "..")
        })
        .unwrap_or(false)
}

/// Check every component of `path` below `root` for ignored directories and
/// hidden entries. Unlike [`is_ignored`], this catches files nested inside an
/// ignored folder (for example `.git/HEAD` or `node_modules/pkg/index.js`).
pub fn is_ignored_below(root: &Path, path: &Path) -> bool {
    let relative = match path.strip_prefix(root) {
        Ok(relative) => relative,
        Err(_) => return is_ignored(path),
    };
    relative.components().any(|component| match component {
        Component::Normal(name) => {
            let name = name.to_string_lossy();
            name != ".env"
                && (IGNORED_DIRS.contains(&name.as_ref())
                    || (name.starts_with('.') && name != "." && name != ".."))
        }
        _ => false,
    })
}

fn is_hidden_file(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .map(|name| name.starts_with('.') && name != ".env" && name != ".gitignore")
        .unwrap_or(false)
}

/// Open (or re-open) a local folder and persist it as a project.
pub fn open_project(storage: &Storage, path: &Path) -> AppResult<Project> {
    let root = std::fs::canonicalize(path)
        .map_err(|error| AppError::validation(format!("Cannot open folder: {}", error)))?;
    if !root.is_dir() {
        return Err(AppError::validation(
            "Stateglass projects must be folders containing source files",
        ));
    }
    let root_string = root.to_string_lossy().to_string();
    let existing = storage.get_project_by_root(&root_string)?;
    let name = root
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("project")
        .to_string();
    let entry = detect_entry(&root);
    let has_python = python_files(&root, 1, MAX_FILE_BYTES).len() > 0;

    let project = match existing {
        Some(mut project) => {
            project.name = name;
            project.last_opened_at = now_ms();
            if project.entry_point.is_none() {
                project.entry_point = entry;
            }
            project
        }
        None => Project {
            id: new_id(),
            name,
            root_path: root_string,
            language: if has_python { "python" } else { "unknown" }.to_string(),
            entry_point: entry,
            run_args: Vec::new(),
            timeout_ms: 20_000,
            tracing: true,
            consent_granted: false,
            python_path: None,
            created_at: now_ms(),
            last_opened_at: now_ms(),
        },
    };
    storage.upsert_project(&project)?;
    let stored = storage.get_project(&project.id)?;
    Ok(stored)
}

/// Pick a sensible entry point. `main.py`/`app.py` first, then the shallowest
/// Python file containing a `__main__` guard, then any top-level Python file.
pub fn detect_entry(root: &Path) -> Option<String> {
    for candidate in ["main.py", "app.py", "__main__.py", "run.py", "manage.py"] {
        if root.join(candidate).is_file() {
            return Some(candidate.to_string());
        }
    }
    let mut fallback: Option<String> = None;
    for entry in WalkDir::new(root)
        .max_depth(3)
        .follow_links(false)
        .into_iter()
        .filter_entry(|entry| entry.depth() == 0 || !is_ignored(entry.path()))
        .flatten()
    {
        let path = entry.path();
        if !path.is_file() || path.extension().and_then(|value| value.to_str()) != Some("py") {
            continue;
        }
        let relative = relative_path(root, path);
        if fallback.is_none() {
            fallback = Some(relative.clone());
        }
        if let Ok(content) = std::fs::read_to_string(path) {
            if content.contains("__name__") && content.contains("__main__") {
                return Some(relative);
            }
        }
    }
    fallback
}

pub fn relative_path(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/")
}

/// Flat file listing; the frontend builds a tree from the paths.
pub fn list_files(root: &Path) -> AppResult<Vec<FileEntry>> {
    let mut entries = Vec::new();
    for entry in WalkDir::new(root)
        .max_depth(MAX_TREE_DEPTH)
        .follow_links(false)
        .sort_by_file_name()
        .into_iter()
        .filter_entry(|entry| {
            entry.depth() == 0 || (!is_ignored(entry.path()) && !is_hidden_file(entry.path()))
        })
        .flatten()
    {
        if entries.len() >= MAX_LISTED_FILES {
            break;
        }
        if entry.depth() == 0 {
            continue;
        }
        let metadata = match entry.metadata() {
            Ok(metadata) => metadata,
            Err(_) => continue,
        };
        let relative = relative_path(root, entry.path());
        entries.push(FileEntry {
            path: relative.clone(),
            name: entry
                .file_name()
                .to_string_lossy()
                .to_string(),
            is_dir: metadata.is_dir(),
            is_python: entry
                .path()
                .extension()
                .and_then(|value| value.to_str())
                .map(|ext| ext.eq_ignore_ascii_case("py"))
                .unwrap_or(false),
            size: if metadata.is_file() { metadata.len() } else { 0 },
        });
    }
    Ok(entries)
}

pub fn python_files(root: &Path, limit: usize, max_bytes: u64) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for entry in WalkDir::new(root)
        .max_depth(MAX_TREE_DEPTH)
        .follow_links(false)
        .sort_by_file_name()
        .into_iter()
        .filter_entry(|entry| entry.depth() == 0 || !is_ignored(entry.path()))
        .flatten()
    {
        if files.len() >= limit {
            break;
        }
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        if path.extension().and_then(|value| value.to_str()) != Some("py") {
            continue;
        }
        if entry.metadata().map(|meta| meta.len() > max_bytes).unwrap_or(true) {
            continue;
        }
        files.push(path.to_path_buf());
    }
    files
}

/// Resolve a project-relative path, refusing absolute paths, `..` traversal and
/// symlinks that escape the project root.
pub fn resolve_inside(root: &Path, relative: &str) -> AppResult<PathBuf> {
    if relative.trim().is_empty() {
        return Err(AppError::validation("File path is empty"));
    }
    let raw = Path::new(relative);
    if raw.is_absolute() {
        return Err(AppError::validation("Absolute file paths are not allowed"));
    }
    for component in raw.components() {
        match component {
            Component::Normal(_) => {}
            Component::CurDir => {}
            _ => {
                return Err(AppError::validation(
                    "File path must stay inside the project folder",
                ))
            }
        }
    }
    let root_canonical = std::fs::canonicalize(root)?;
    let candidate = root_canonical.join(raw);
    let resolved = match std::fs::canonicalize(&candidate) {
        Ok(path) => path,
        Err(_) => {
            let parent = candidate
                .parent()
                .ok_or_else(|| AppError::validation("Invalid file path"))?;
            let parent = std::fs::canonicalize(parent)
                .map_err(|_| AppError::validation("Parent folder does not exist"))?;
            match candidate.file_name() {
                Some(name) => parent.join(name),
                None => parent,
            }
        }
    };
    if !resolved.starts_with(&root_canonical) {
        return Err(AppError::validation(
            "File path resolves outside the project folder",
        ));
    }
    Ok(resolved)
}

pub fn read_text(root: &Path, relative: &str) -> AppResult<FileContent> {
    let path = resolve_inside(root, relative)?;
    if !path.is_file() {
        return Err(AppError::not_found(format!("File not found: {}", relative)));
    }
    let metadata = std::fs::metadata(&path)?;
    if metadata.len() > MAX_FILE_BYTES {
        return Err(AppError::validation(format!(
            "File is too large to open in the editor ({} KB)",
            metadata.len() / 1024
        )));
    }
    let bytes = std::fs::read(&path)?;
    if bytes.iter().take(8192).any(|byte| *byte == 0) {
        return Err(AppError::validation(
            "This looks like a binary file and cannot be opened in the text editor",
        ));
    }
    let content = String::from_utf8(bytes).map_err(|_| {
        AppError::validation("File is not valid UTF-8 text; only text files can be edited")
    })?;
    let modified_at = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0);
    Ok(FileContent {
        path: relative.to_string(),
        size: metadata.len(),
        language: language_for(&path),
        content,
        modified_at,
    })
}

pub fn write_text(root: &Path, relative: &str, content: &str) -> AppResult<FileContent> {
    let path = resolve_inside(root, relative)?;
    if !path.is_file() {
        return Err(AppError::not_found(format!(
            "File not found: {} (Stateglass edits existing files only)",
            relative
        )));
    }
    if content.len() as u64 > MAX_FILE_BYTES {
        return Err(AppError::validation(
            "Refusing to write a file larger than the editor limit",
        ));
    }
    std::fs::write(&path, content.as_bytes())?;
    read_text(root, relative)
}

pub fn language_for(path: &Path) -> String {
    match path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "py" | "pyi" => "python",
        "ts" | "tsx" => "typescript",
        "js" | "jsx" | "mjs" | "cjs" => "javascript",
        "json" => "json",
        "md" | "markdown" => "markdown",
        "toml" => "toml",
        "yaml" | "yml" => "yaml",
        "rs" => "rust",
        "css" => "css",
        "html" => "html",
        "sh" | "bash" | "zsh" => "shell",
        "txt" => "plaintext",
        "ini" | "cfg" => "ini",
        "sql" => "sql",
        _ => "plaintext",
    }
    .to_string()
}

// ---------------------------------------------------------------------------
// Bundled sample project
// ---------------------------------------------------------------------------

const SAMPLE_MAIN: &str = include_str!("../../samples/python-demo/main.py");
const SAMPLE_CATALOG: &str = include_str!("../../samples/python-demo/catalog.py");
const SAMPLE_DISCOUNTS: &str = include_str!("../../samples/python-demo/discounts.py");
const SAMPLE_PRICING: &str = include_str!("../../samples/python-demo/pricing.py");
const SAMPLE_README: &str = include_str!("../../samples/python-demo/README.md");

/// Write the bundled demo project into `directory` (idempotent).
pub fn create_sample_project(directory: &Path) -> AppResult<()> {
    if directory.join("main.py").is_file() {
        return Ok(());
    }
    std::fs::create_dir_all(directory)?;
    for (name, content) in [
        ("main.py", SAMPLE_MAIN),
        ("catalog.py", SAMPLE_CATALOG),
        ("discounts.py", SAMPLE_DISCOUNTS),
        ("pricing.py", SAMPLE_PRICING),
        ("README.md", SAMPLE_README),
    ] {
        std::fs::write(directory.join(name), content)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn rejects_path_traversal_and_absolute_paths() {
        let dir = tempdir().unwrap();
        std::fs::write(dir.path().join("a.py"), "print(1)").unwrap();
        assert!(resolve_inside(dir.path(), "a.py").is_ok());
        assert!(resolve_inside(dir.path(), "../a.py").is_err());
        assert!(resolve_inside(dir.path(), "/etc/passwd").is_err());
        assert!(resolve_inside(dir.path(), "nested/../../a.py").is_err());
    }

    #[test]
    fn reads_writes_and_rejects_binaries() {
        let dir = tempdir().unwrap();
        std::fs::write(dir.path().join("a.py"), "x = 1\n").unwrap();
        let content = read_text(dir.path(), "a.py").unwrap();
        assert_eq!(content.language, "python");
        assert_eq!(content.content, "x = 1\n");
        write_text(dir.path(), "a.py", "x = 2\n").unwrap();
        assert_eq!(read_text(dir.path(), "a.py").unwrap().content, "x = 2\n");

        std::fs::write(dir.path().join("bin.dat"), [0u8, 1, 2, 3]).unwrap();
        let error = read_text(dir.path(), "bin.dat").unwrap_err();
        assert!(error.to_string().contains("binary"));
    }

    #[test]
    fn ignores_nested_paths_inside_ignored_folders() {
        let root = Path::new("/work/demo");
        assert!(is_ignored_below(root, Path::new("/work/demo/.git/HEAD")));
        assert!(is_ignored_below(
            root,
            Path::new("/work/demo/node_modules/pkg/index.js")
        ));
        assert!(is_ignored_below(
            root,
            Path::new("/work/demo/__pycache__/main.cpython-312.pyc")
        ));
        assert!(!is_ignored_below(root, Path::new("/work/demo/main.py")));
        assert!(!is_ignored_below(root, Path::new("/work/demo/pkg/.env")));
        // The project root itself is always relevant.
        assert!(!is_ignored_below(root, root));
    }

    #[test]
    fn detects_entry_points() {
        let dir = tempdir().unwrap();
        std::fs::write(dir.path().join("other.py"), "print('a')").unwrap();
        assert_eq!(detect_entry(dir.path()).as_deref(), Some("other.py"));
        std::fs::write(
            dir.path().join("other.py"),
            "if __name__ == '__main__':\n    pass\n",
        )
        .unwrap();
        std::fs::write(dir.path().join("main.py"), "print(1)").unwrap();
        assert_eq!(detect_entry(dir.path()).as_deref(), Some("main.py"));
    }

    #[test]
    fn lists_files_but_skips_ignored_directories() {
        let dir = tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("pkg")).unwrap();
        std::fs::create_dir_all(dir.path().join("__pycache__")).unwrap();
        std::fs::create_dir_all(dir.path().join(".git")).unwrap();
        std::fs::write(dir.path().join("pkg/a.py"), "").unwrap();
        std::fs::write(dir.path().join("__pycache__/a.pyc"), "").unwrap();
        std::fs::write(dir.path().join(".git/config"), "").unwrap();
        let entries = list_files(dir.path()).unwrap();
        let paths: Vec<_> = entries.iter().map(|entry| entry.path.as_str()).collect();
        assert!(paths.contains(&"pkg/a.py"));
        assert!(!paths.iter().any(|path| path.contains("__pycache__")));
        assert!(!paths.iter().any(|path| path.contains(".git")));
        assert!(entries.iter().any(|entry| entry.is_dir && entry.path == "pkg"));
    }

    #[test]
    fn creates_the_sample_project_once() {
        let dir = tempdir().unwrap();
        let sample = dir.path().join("sample");
        create_sample_project(&sample).unwrap();
        assert!(sample.join("pricing.py").is_file());
        std::fs::write(sample.join("pricing.py"), "# edited\n").unwrap();
        create_sample_project(&sample).unwrap();
        assert_eq!(
            std::fs::read_to_string(sample.join("pricing.py")).unwrap(),
            "# edited\n"
        );
    }
}
