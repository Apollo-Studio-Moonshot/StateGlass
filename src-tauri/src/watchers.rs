//! Filesystem monitoring for open workspaces (original projects and
//! experiment copies). Changes are debounced and surfaced to the UI so the
//! explorer and editor can stay in sync with the disk.

use crate::error::{AppError, AppResult};
use crate::execution::EventSink;
use crate::project::is_ignored_below;
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub struct WatchManager {
    watchers: Mutex<HashMap<String, RecommendedWatcher>>,
    sink: Arc<dyn EventSink>,
}

impl WatchManager {
    pub fn new(sink: Arc<dyn EventSink>) -> Self {
        Self {
            watchers: Mutex::new(HashMap::new()),
            sink,
        }
    }

    pub fn watch(&self, workspace_id: &str, root: &Path) -> AppResult<()> {
        let workspace = workspace_id.to_string();
        let root_for_handler = root.to_path_buf();
        let last_emit = Arc::new(Mutex::new(Instant::now() - Duration::from_secs(10)));
        let sink = self.sink.clone();
        let workspace_for_handler = workspace.clone();
        let mut watcher =
            notify::recommended_watcher(move |result: Result<notify::Event, notify::Error>| {
                let Ok(event) = result else { return };
                let relevant = event.paths.iter().any(|path| {
                    !is_ignored_below(&root_for_handler, path)
                        && path
                            .file_name()
                            .and_then(|name| name.to_str())
                            .map(|name| !name.ends_with(".sqlite3-wal") && !name.ends_with(".swp"))
                            .unwrap_or(false)
                });
                if !relevant {
                    return;
                }
                if let Ok(mut last) = last_emit.lock() {
                    if last.elapsed() < Duration::from_millis(250) {
                        return;
                    }
                    *last = Instant::now();
                }
                let paths: Vec<String> = event
                    .paths
                    .iter()
                    .map(|path| path.to_string_lossy().to_string())
                    .collect();
                sink.emit(
                    "workspace:changed",
                    serde_json::json!({
                        "workspaceId": workspace_for_handler,
                        "paths": paths,
                        "kind": format!("{:?}", event.kind),
                    }),
                );
            })
            .map_err(|error| {
                AppError::message(format!("Could not start file watcher: {}", error))
            })?;

        watcher
            .watch(root, RecursiveMode::Recursive)
            .map_err(|error| {
                AppError::message(format!("Could not watch project folder: {}", error))
            })?;

        if let Ok(mut map) = self.watchers.lock() {
            map.insert(workspace, watcher);
        }
        Ok(())
    }
}
