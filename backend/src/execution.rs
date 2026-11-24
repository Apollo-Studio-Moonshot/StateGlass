//! Execution engine: launches the Python helper in a child process, streams
//! output and trace events to the UI, enforces timeouts and cleans up process
//! groups.

use crate::error::{AppError, AppResult};
use crate::models::*;
use crate::project::resolve_inside;
use crate::storage::Storage;
use crate::tracing::{
    take_events, TRACE_MAX_DEPTH, TRACE_MAX_EVENTS, TRACE_MAX_LOCALS, TRACE_VALUE_LENGTH,
};
use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use sysinfo::{Pid, ProcessesToUpdate, System};
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio::time::{interval, sleep, MissedTickBehavior};

const MAX_OUTPUT_BYTES: usize = 3_000_000;
const STDERR_SCAN_LIMIT: usize = 400;

/// Abstraction over event emission so the execution engine can be tested
/// without a running sidecar.
pub trait EventSink: Send + Sync + 'static {
    fn emit(&self, event: &str, payload: serde_json::Value);
}

fn runtime() -> &'static tokio::runtime::Runtime {
    use std::sync::OnceLock;
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("stateglass")
            .build()
            .expect("failed to start the Stateglass runtime")
    })
}

#[derive(Debug, Clone)]
pub struct RunSpec {
    pub project_id: String,
    pub experiment_id: Option<String>,
    pub label: Option<String>,
    pub root: PathBuf,
    pub python: String,
    pub tracer: PathBuf,
    /// Entry point, relative to `root`.
    pub entry: String,
    pub args: Vec<String>,
    pub stdin: Option<String>,
    pub timeout_ms: u64,
    /// When false, the program runs without instrumentation (no trace file).
    pub trace_enabled: bool,
}

#[derive(Default, Clone)]
struct OutputState {
    stdout: String,
    stderr: String,
    stdout_bytes: u64,
    stderr_bytes: u64,
    stdout_truncated: bool,
    stderr_truncated: bool,
}

struct RunHandle {
    cancel: Arc<AtomicBool>,
    pid: Arc<AtomicU32>,
}

#[derive(Default, Clone)]
struct TraceTailInfo {
    saw_end: bool,
    status: Option<String>,
    exit_code: Option<i32>,
    error: Option<String>,
    truncated: bool,
    python: Option<String>,
}

pub struct ExecutionManager {
    storage: Arc<Storage>,
    sink: Arc<dyn EventSink>,
    data_dir: PathBuf,
    running: Arc<Mutex<HashMap<String, RunHandle>>>,
}

impl ExecutionManager {
    pub fn new(storage: Arc<Storage>, sink: Arc<dyn EventSink>, data_dir: PathBuf) -> Self {
        Self {
            storage,
            sink,
            data_dir,
            running: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn is_running(&self, session_id: &str) -> bool {
        self.running
            .lock()
            .map(|map| map.contains_key(session_id))
            .unwrap_or(false)
    }

    /// Start an execution and return immediately with the `running` session.
    pub fn start(&self, spec: RunSpec) -> AppResult<Session> {
        let entry_path = resolve_inside(&spec.root, &spec.entry)?;
        if !entry_path.is_file() {
            return Err(AppError::validation(format!(
                "Entry point not found: {}",
                spec.entry
            )));
        }
        if spec.trace_enabled && !spec.tracer.is_file() {
            return Err(AppError::execution(
                "The Python instrumentation helper could not be found. Reinstall Stateglass or set STATEGLASS_TRACER.",
            ));
        }
        let timeout_ms = spec.timeout_ms.clamp(1_000, 600_000);
        let session_id = new_id();
        let trace_dir = self.data_dir.join("traces");
        std::fs::create_dir_all(&trace_dir)?;
        let trace_path = trace_dir.join(format!("{}.ndjson", session_id));

        let command = format!(
            "{} {}",
            Path::new(&spec.python)
                .file_name()
                .map(|name| name.to_string_lossy().to_string())
                .unwrap_or_else(|| spec.python.clone()),
            spec.entry
        );
        let command = if spec.args.is_empty() {
            command
        } else {
            format!("{} {}", command, spec.args.join(" "))
        };

        let session = Session {
            id: session_id.clone(),
            project_id: spec.project_id.clone(),
            experiment_id: spec.experiment_id.clone(),
            kind: if spec.experiment_id.is_some() {
                "experiment".to_string()
            } else {
                "baseline".to_string()
            },
            label: spec.label.clone(),
            command,
            args: spec.args.clone(),
            stdin: spec.stdin.clone(),
            cwd: spec.root.to_string_lossy().to_string(),
            entry_file: Some(spec.entry.clone()),
            python: spec.python.clone(),
            status: "running".to_string(),
            exit_code: None,
            started_at: now_ms(),
            finished_at: None,
            duration_ms: None,
            peak_memory_bytes: None,
            timeout_ms: timeout_ms as i64,
            error: None,
            stdout_preview: String::new(),
            stderr_preview: String::new(),
            stdout_bytes: 0,
            stderr_bytes: 0,
            trace_event_count: 0,
            trace_truncated: false,
        };
        self.storage.insert_session(&session, &trace_path.to_string_lossy())?;

        let handle = RunHandle {
            cancel: Arc::new(AtomicBool::new(false)),
            pid: Arc::new(AtomicU32::new(0)),
        };
        let cancel = handle.cancel.clone();
        let pid = handle.pid.clone();
        if let Ok(mut map) = self.running.lock() {
            map.insert(session_id.clone(), handle);
        }

        let storage = self.storage.clone();
        let sink = self.sink.clone();
        let running = self.running.clone();
        let session_for_task = session.clone();
        let trace_path_for_task = trace_path;
        let spec_for_task = spec;
        runtime().spawn(async move {
            execute_run(
                storage,
                sink,
                running,
                session_for_task,
                spec_for_task,
                trace_path_for_task,
                cancel,
                pid,
                timeout_ms,
            )
            .await;
        });

        Ok(session)
    }

    /// Request cancellation and kill the process group immediately.
    pub fn cancel(&self, session_id: &str) -> AppResult<()> {
        let map = self
            .running
            .lock()
            .map_err(|_| AppError::message("Execution registry lock was poisoned"))?;
        let handle = map
            .get(session_id)
            .ok_or_else(|| AppError::validation("This execution is no longer running"))?;
        handle.cancel.store(true, Ordering::SeqCst);
        let pid = handle.pid.load(Ordering::SeqCst);
        kill_tree(pid);
        Ok(())
    }

    pub fn shutdown_all(&self) {
        if let Ok(map) = self.running.lock() {
            for handle in map.values() {
                handle.cancel.store(true, Ordering::SeqCst);
                let pid = handle.pid.load(Ordering::SeqCst);
                kill_tree(pid);
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn execute_run(
    storage: Arc<Storage>,
    sink: Arc<dyn EventSink>,
    running: Arc<Mutex<HashMap<String, RunHandle>>>,
    session: Session,
    spec: RunSpec,
    trace_path: PathBuf,
    cancel: Arc<AtomicBool>,
    pid_slot: Arc<AtomicU32>,
    timeout_ms: u64,
) {
    let session_id = session.id.clone();
    let started = Instant::now();
    let output = Arc::new(Mutex::new(OutputState::default()));
    let trace_count = Arc::new(AtomicI64::new(0));
    let tail_info = Arc::new(Mutex::new(TraceTailInfo::default()));
    let tail_stop = Arc::new(AtomicBool::new(false));

    let entry_path = match resolve_inside(&spec.root, &spec.entry) {
        Ok(path) => path,
        Err(error) => {
            finalize_failure(&storage, &sink, &session, &error.to_string(), started);
            cleanup(&running, &session_id);
            return;
        }
    };

    let mut command = Command::new(&spec.python);
    command
        .current_dir(&spec.root)
        .env("PYTHONUNBUFFERED", "1")
        .env("PYTHONIOENCODING", "utf-8")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    if spec.trace_enabled {
        command
            .arg(&spec.tracer)
            .arg("run")
            .arg("--trace-file")
            .arg(&trace_path)
            .arg("--root")
            .arg(&spec.root)
            .arg("--events-limit")
            .arg(TRACE_MAX_EVENTS.to_string())
            .arg("--value-limit")
            .arg(TRACE_VALUE_LENGTH.to_string())
            .arg("--max-depth")
            .arg(TRACE_MAX_DEPTH.to_string())
            .arg("--max-locals")
            .arg(TRACE_MAX_LOCALS.to_string())
            .arg("--");
    }
    command.arg(&entry_path).args(&spec.args);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.as_std_mut().process_group(0);
    }

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            finalize_failure(
                &storage,
                &sink,
                &session,
                &format!("Could not start Python ({}): {}", spec.python, error),
                started,
            );
            cleanup(&running, &session_id);
            return;
        }
    };

    let pid = child.id().unwrap_or(0);
    pid_slot.store(pid, Ordering::SeqCst);
    if cancel.load(Ordering::SeqCst) {
        kill_tree(pid);
    }

    if let Some(mut stdin) = child.stdin.take() {
        let payload = spec.stdin.clone().unwrap_or_default();
        if !payload.is_empty() {
            tokio::spawn(async move {
                use tokio::io::AsyncWriteExt;
                let _ = stdin.write_all(payload.as_bytes()).await;
                let _ = stdin.shutdown().await;
            });
        }
    }

    let mut readers = Vec::new();
    if let Some(stdout) = child.stdout.take() {
        readers.push(tokio::spawn(read_pipe(
            stdout,
            "stdout",
            session_id.clone(),
            sink.clone(),
            output.clone(),
        )));
    }
    if let Some(stderr) = child.stderr.take() {
        readers.push(tokio::spawn(read_pipe(
            stderr,
            "stderr",
            session_id.clone(),
            sink.clone(),
            output.clone(),
        )));
    }

    let tail_handle = spawn_trace_tail(
        trace_path.clone(),
        session_id.clone(),
        storage.clone(),
        sink.clone(),
        tail_stop.clone(),
        trace_count.clone(),
        tail_info.clone(),
    );

    let mut system = System::new();
    let mut peak_memory: u64 = 0;
    let mut ticker = interval(Duration::from_millis(200));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    let deadline = sleep(Duration::from_millis(timeout_ms));
    tokio::pin!(deadline);

    let mut exit_status: Option<std::process::ExitStatus> = None;
    let mut timed_out = false;
    let mut cancelled = false;
    let mut kill_fallback: Option<Instant> = None;

    loop {
        tokio::select! {
            biased;
            status = child.wait() => {
                match status {
                    Ok(status) => exit_status = Some(status),
                    Err(error) => {
                        tracing::warn!(%error, "Failed to wait for child process");
                    }
                }
                break;
            }
            _ = &mut deadline => {
                timed_out = true;
                kill_tree(pid);
                kill_fallback = Some(Instant::now());
            }
            _ = ticker.tick() => {
                if cancel.load(Ordering::SeqCst) && !cancelled {
                    cancelled = true;
                    kill_tree(pid);
                    kill_fallback = Some(Instant::now());
                }
                if let Some(sent) = kill_fallback {
                    if sent.elapsed() > Duration::from_secs(3) {
                        kill_tree(pid);
                        kill_fallback = Some(Instant::now());
                    }
                }
                if pid != 0 {
                    let process_id = Pid::from_u32(pid);
                    system.refresh_processes(ProcessesToUpdate::Some(&[process_id]), true);
                    if let Some(process) = system.process(process_id) {
                        peak_memory = peak_memory.max(process.memory());
                    }
                }
                sink.emit(
                    "run:stats",
                    serde_json::json!({
                        "sessionId": session_id,
                        "elapsedMs": started.elapsed().as_millis() as i64,
                        "peakMemoryBytes": peak_memory as i64,
                        "traceEvents": trace_count.load(Ordering::SeqCst),
                    }),
                );
            }
        }
    }

    drop(child);
    for reader in readers {
        let _ = tokio::time::timeout(Duration::from_secs(2), reader).await;
    }

    tail_stop.store(true, Ordering::SeqCst);
    let _ = tokio::time::timeout(Duration::from_secs(5), tail_handle).await;

    let duration_ms = started.elapsed().as_millis() as i64;
    let exit_code = exit_status.and_then(|status| status.code());
    let info = tail_info
        .lock()
        .map(|value| value.clone())
        .unwrap_or_default();
    let trace_events = trace_count.load(Ordering::SeqCst);
    // `cancel` kills the process immediately, so `wait()` can win the race
    // against the ticker that records `cancelled`. Honour the flag here too.
    let was_cancelled = cancelled || cancel.load(Ordering::SeqCst);

    let status = if was_cancelled {
        "cancelled"
    } else if timed_out {
        "timeout"
    } else if info.status.as_deref() == Some("error") {
        "error"
    } else if matches!(exit_code, Some(0)) {
        "ok"
    } else if exit_code.is_none() {
        "crashed"
    } else {
        "error"
    };

    let error_message = if timed_out {
        Some(format!(
            "Execution exceeded the {}s timeout and was terminated.",
            timeout_ms / 1000
        ))
    } else if was_cancelled {
        Some("Execution was cancelled.".to_string())
    } else if let Some(error) = info.error.clone() {
        Some(error)
    } else if status == "crashed" {
        Some("The interpreter exited without an exit code.".to_string())
    } else {
        None
    };

    let (stdout, stderr, stdout_bytes, stderr_bytes) = {
        let state = output.lock().map(|value| value.clone()).unwrap_or_default();
        (state.stdout, state.stderr, state.stdout_bytes, state.stderr_bytes)
    };

    let finished = storage.finish_session(
        &session_id,
        status,
        exit_code,
        now_ms(),
        duration_ms,
        if peak_memory > 0 {
            Some(peak_memory as i64)
        } else {
            None
        },
        error_message.as_deref(),
        &stdout,
        &stderr,
        trace_events,
        info.truncated,
    );

    if let Err(error) = finished {
        tracing::error!(%error, "Failed to persist finished session");
    }

    if let Ok(updated) = storage.get_session(&session_id) {
        sink.emit(
            "run:finished",
            serde_json::to_value(&updated).unwrap_or(serde_json::Value::Null),
        );
    } else {
        sink.emit(
            "run:finished",
            serde_json::json!({
                "sessionId": session_id,
                "status": status,
                "error": error_message,
                "durationMs": duration_ms,
                "exitCode": exit_code,
                "traceEventCount": trace_events,
                "stdoutBytes": stdout_bytes,
                "stderrBytes": stderr_bytes,
            }),
        );
    }

    cleanup(&running, &session_id);
}

fn finalize_failure(
    storage: &Storage,
    sink: &Arc<dyn EventSink>,
    session: &Session,
    message: &str,
    started: Instant,
) {
    let duration = started.elapsed().as_millis() as i64;
    let _ = storage.finish_session(
        &session.id,
        "error",
        None,
        now_ms(),
        duration,
        None,
        Some(message),
        "",
        "",
        0,
        false,
    );
    if let Ok(updated) = storage.get_session(&session.id) {
        sink.emit(
            "run:finished",
            serde_json::to_value(&updated).unwrap_or(serde_json::Value::Null),
        );
    }
}

fn cleanup(running: &Arc<Mutex<HashMap<String, RunHandle>>>, session_id: &str) {
    if let Ok(mut map) = running.lock() {
        map.remove(session_id);
    }
}

fn append_capped(target: &mut String, chunk: &str, max: usize) -> bool {
    if target.len() >= max {
        return true;
    }
    let remaining = max - target.len();
    if chunk.len() <= remaining {
        target.push_str(chunk);
        false
    } else {
        let mut end = remaining;
        while end > 0 && !chunk.is_char_boundary(end) {
            end -= 1;
        }
        target.push_str(&chunk[..end]);
        true
    }
}

async fn read_pipe<R>(
    mut reader: R,
    stream: &'static str,
    session_id: String,
    sink: Arc<dyn EventSink>,
    output: Arc<Mutex<OutputState>>,
) where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut buffer = vec![0u8; 16 * 1024];
    loop {
        match reader.read(&mut buffer).await {
            Ok(0) => break,
            Ok(count) => {
                let chunk = String::from_utf8_lossy(&buffer[..count]).to_string();
                if let Ok(mut state) = output.lock() {
                    if stream == "stdout" {
                        state.stdout_bytes += count as u64;
                        if append_capped(&mut state.stdout, &chunk, MAX_OUTPUT_BYTES) {
                            state.stdout_truncated = true;
                        }
                    } else {
                        state.stderr_bytes += count as u64;
                        if append_capped(&mut state.stderr, &chunk, MAX_OUTPUT_BYTES) {
                            state.stderr_truncated = true;
                        }
                    }
                }
                sink.emit(
                    "run:output",
                    serde_json::json!({
                        "sessionId": session_id,
                        "stream": stream,
                        "chunk": chunk,
                    }),
                );
            }
            Err(error) => {
                if error.kind() != std::io::ErrorKind::Interrupted {
                    break;
                }
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn spawn_trace_tail(
    path: PathBuf,
    session_id: String,
    storage: Arc<Storage>,
    sink: Arc<dyn EventSink>,
    stop: Arc<AtomicBool>,
    count: Arc<AtomicI64>,
    info: Arc<Mutex<TraceTailInfo>>,
) -> tokio::task::JoinHandle<()> {
    tokio::task::spawn_blocking(move || {
        let mut file: Option<std::fs::File> = None;
        let mut offset: u64 = 0;
        let mut pending: Vec<u8> = Vec::new();
        let mut chunk = Vec::new();

        loop {
            if file.is_none() {
                file = std::fs::File::open(&path).ok();
            }
            if let Some(handle) = file.as_mut() {
                chunk.clear();
                let read = handle
                    .seek(SeekFrom::Start(offset))
                    .and_then(|_| handle.read_to_end(&mut chunk));
                match read {
                    Ok(0) => {}
                    Ok(bytes) => {
                        offset += bytes as u64;
                        pending.extend_from_slice(&chunk);
                        let raw = take_events(&mut pending, false);
                        process_tail_events(
                            &raw,
                            &session_id,
                            &storage,
                            &sink,
                            &count,
                            &info,
                        );
                    }
                    Err(_) => {
                        file = None;
                    }
                }
            }

            if stop.load(Ordering::SeqCst) {
                // Final pass to catch anything written between the last read and
                // process exit, then flush a trailing partial line.
                if let Some(handle) = file.as_mut() {
                    chunk.clear();
                    if let Ok(bytes) = handle
                        .seek(SeekFrom::Start(offset))
                        .and_then(|_| handle.read_to_end(&mut chunk))
                    {
                        if bytes > 0 {
                            pending.extend_from_slice(&chunk);
                        }
                    }
                }
                let raw = take_events(&mut pending, true);
                process_tail_events(&raw, &session_id, &storage, &sink, &count, &info);
                break;
            }
            std::thread::sleep(Duration::from_millis(120));
        }
    })
}

fn process_tail_events(
    events: &[RawTraceEvent],
    session_id: &str,
    storage: &Storage,
    sink: &Arc<dyn EventSink>,
    count: &Arc<AtomicI64>,
    info: &Arc<Mutex<TraceTailInfo>>,
) {
    if events.is_empty() {
        return;
    }
    if let Ok(mut state) = info.lock() {
        for event in events {
            match event.kind.as_str() {
                "session_end" => {
                    state.saw_end = true;
                    state.status = event.status.clone();
                    state.exit_code = event.exit_code;
                    state.error = event.error.clone();
                }
                "session_start" => {
                    state.python = event.python.clone();
                }
                "truncated" => {
                    state.truncated = true;
                }
                _ => {}
            }
        }
    }
    match storage.insert_trace_batch(session_id, events) {
        Ok(inserted) => {
            let total = count.fetch_add(inserted.len() as i64, Ordering::SeqCst)
                + inserted.len() as i64;
            sink.emit(
                "run:trace",
                serde_json::json!({
                    "sessionId": session_id,
                    "events": inserted,
                    "total": total,
                }),
            );
        }
        Err(error) => {
            tracing::error!(%error, "Failed to persist trace events");
        }
    }
}

/// Kill the child and any descendants. On Unix the child is started in its own
/// process group, so the whole group can be terminated at once.
pub fn kill_tree(pid: u32) {
    if pid == 0 {
        return;
    }
    #[cfg(unix)]
    unsafe {
        libc::kill(-(pid as i32), libc::SIGKILL);
        libc::kill(pid as i32, libc::SIGKILL);
    }
    #[cfg(windows)]
    {
        let _ = std::process::Command::new("taskkill")
            .args(["/PID", &pid.to_string(), "/T", "/F"])
            .output();
    }
}

/// First few hundred characters of stderr, used in compact UI surfaces.
pub fn stderr_excerpt(stderr: &str) -> String {
    stderr.chars().take(STDERR_SCAN_LIMIT).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appends_output_without_splitting_utf8() {
        let mut buffer = String::new();
        let chunk = "héllo wörld";
        let truncated = append_capped(&mut buffer, chunk, 5);
        assert!(truncated);
        assert!(buffer.is_char_boundary(buffer.len()));
        assert_eq!(buffer, "héll");
    }

    #[test]
    fn kills_do_not_panic_for_unused_pid() {
        kill_tree(0);
        kill_tree(4_000_000_000);
    }

    #[test]
    fn stderr_excerpt_is_bounded() {
        let text = "x".repeat(1000);
        assert_eq!(stderr_excerpt(&text).chars().count(), STDERR_SCAN_LIMIT);
    }
}
