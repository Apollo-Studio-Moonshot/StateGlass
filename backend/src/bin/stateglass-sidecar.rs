use serde::Deserialize;
use serde_json::{json, Value};
use stateglass_lib::execution::EventSink;
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

struct JsonLineSink {
    stdout: Arc<Mutex<io::Stdout>>,
}

impl JsonLineSink {
    fn write(&self, value: &Value) {
        if let Ok(mut stdout) = self.stdout.lock() {
            if let Err(error) = writeln!(stdout, "{value}").and_then(|_| stdout.flush()) {
                eprintln!("Could not write sidecar message: {error}");
            }
        }
    }
}

impl EventSink for JsonLineSink {
    fn emit(&self, event: &str, payload: Value) {
        self.write(&json!({
            "kind": "event",
            "protocolVersion": stateglass_lib::sidecar::PROTOCOL_VERSION,
            "event": event,
            "payload": payload,
        }));
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    id: Value,
    method: String,
    protocol_version: u32,
    #[serde(default)]
    params: Value,
}

fn data_dir() -> PathBuf {
    if let Ok(path) = std::env::var("STATEGLASS_DATA_DIR") {
        return PathBuf::from(path);
    }
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Library")
        .join("Application Support")
        .join("dev.stateglass.app")
}

fn resource_dir() -> Option<PathBuf> {
    let executable = std::env::current_exe().ok()?;
    let parent = executable.parent()?;
    Some(parent.join("../Resources"))
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    stateglass_lib::init_logging();
    let stdout = Arc::new(Mutex::new(io::stdout()));
    let sink = Arc::new(JsonLineSink {
        stdout: stdout.clone(),
    });
    let resource_dir = resource_dir();
    let state =
        stateglass_lib::create_state(data_dir(), sink.clone(), None, resource_dir.as_deref())?;

    for line in io::stdin().lock().lines() {
        let line = line?;
        let parsed: Result<Request, _> = serde_json::from_str(&line);
        match parsed {
            Ok(request) => {
                if request.protocol_version != stateglass_lib::sidecar::PROTOCOL_VERSION {
                    sink.write(&json!({
                        "kind": "response",
                        "protocolVersion": stateglass_lib::sidecar::PROTOCOL_VERSION,
                        "id": request.id,
                        "error": {
                            "kind": "protocol_version",
                            "message": format!(
                                "Unsupported sidecar protocol version: {}",
                                request.protocol_version
                            ),
                        },
                    }));
                    continue;
                }
                let result =
                    stateglass_lib::sidecar::dispatch(&state, &request.method, request.params);
                let response = match result {
                    Ok(result) => json!({
                        "kind": "response",
                        "protocolVersion": stateglass_lib::sidecar::PROTOCOL_VERSION,
                        "id": request.id,
                        "result": result,
                    }),
                    Err(error) => json!({
                        "kind": "response",
                        "protocolVersion": stateglass_lib::sidecar::PROTOCOL_VERSION,
                        "id": request.id,
                        "error": error,
                    }),
                };
                sink.write(&response);
            }
            Err(error) => {
                sink.write(&json!({
                    "kind": "protocolError",
                    "protocolVersion": stateglass_lib::sidecar::PROTOCOL_VERSION,
                    "error": error.to_string(),
                }));
            }
        }
    }

    state.executions.shutdown_all();
    Ok(())
}
