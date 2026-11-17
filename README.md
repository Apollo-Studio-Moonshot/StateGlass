# Stateglass

Stateglass is a desktop debugging IDE built around two questions:

1. **Where did this incorrect value come from?**
2. **What happens if I change the code that produced it?**

Instead of stopping at breakpoints, Stateglass records an execution trace, lets you
inspect every recorded variable change with its function and source line, draws a
data-flow graph from static assignments plus runtime snapshots, and lets you run
isolated experiments against the same recorded command so you can compare both
executions side by side.

The original project folder is never modified when creating or running experiments.

> **Status:** the first version is functional end to end for Python 3.11+. The
> architecture keeps execution/language support behind explicit boundaries so other
> runtimes can be added later; only Python is implemented today.

---

## Contents

- [Features](#features)
- [Quick start](#quick-start)
- [A five-minute tour](#a-five-minute-tour)
- [Architecture](#architecture)
- [How tracing works](#how-tracing-works)
- [How data flow is built](#how-data-flow-is-built)
- [Experiments and comparison](#experiments-and-comparison)
- [Persistence and local data](#persistence-and-local-data)
- [Security, limits and honest caveats](#security-limits-and-honest-caveats)
- [Testing](#testing)
- [Repository layout](#repository-layout)
- [Extending to other languages](#extending-to-other-languages)
- [Development utilities](#development-utilities)
- [Troubleshooting](#troubleshooting)
- [Non-goals](#non-goals)

---

## Features

| Area | What works today |
| --- | --- |
| Projects | Open any local folder, file tree with ignore rules, safe path resolution, entry-point detection, persisted run settings, filesystem watching, recent projects |
| Editor | Native SwiftUI text editor, multiple tabs, dirty tracking, `⌘S`, and source navigation from trace events |
| Execution | Python child process, stdout/stderr streamed live, exit codes, timeout with process-group termination, cancellation, peak memory, duration |
| Tracing | `sys.settrace` helper, NDJSON events, variable history, call/return/exception events, per-line attribution, configurable limits, truncation signalling |
| Inspection | Variables at any point in the timeline, history for a selected variable, function/line navigation, interactive timeline with filters and scrubbing |
| Data flow | AST assignment metadata joined with runtime snapshots, Metal-backed graph rendering, assignment site table, source navigation |
| Experiments | Isolated project copies, multiple experiments per baseline, replay of recorded entry point/args/stdin/timeout, edit the copy without touching the original |
| Comparison | Side-by-side metrics, unified output/error diffs, variable diff table, explicit nondeterminism warnings |
| SoloVibe canvas | Local-first context nodes for frontend, billing, marketing, and database work; dependency mapping and review warnings when upstream schema context changes |
| UX | Dark theme, native resizable panes, keyboard shortcuts, loading/empty states, live status, graceful errors |

---

## Quick start

### Requirements

- macOS 14 or newer, Xcode with Swift 6, and Rust 1.77+
- Python **3.11 or newer** on `PATH` (a project `.venv` is detected automatically)
- No Node.js, cloud account, API key, telemetry, or network service is required

### Install and run

```bash
npm run dev          # builds the Rust sidecar and launches the native SwiftUI app
```

Build a standalone `.app` bundle:

```bash
npm run build
open build/Stateglass.app
```

Set `STATEGLASS_APP_OUTPUT` to place the app bundle elsewhere. To open it as
part of the build command, use `bash scripts/build-macos.sh --open`.

The bundled sample lives at [`samples/python-demo`](samples/python-demo). Choose
**Load Sample Project** on the welcome screen to copy it into the app data
directory and open it.

---

## A five-minute tour

The sample is a four-file pricing pipeline with one intentional bug.

1. **Open the sample** and press `⌘↵`. The first
   run asks for consent, then starts a traced baseline execution.
2. Watch stdout stream in the console; the timeline fills with variable, call and
   exception events.
3. Select `total` in the **Variables** inspector. Its history shows every recorded
   assignment with the function and line that produced it.
4. Click a history row to move the timeline cursor to that moment, or use the arrow
   button to jump to the exact source line. The changed line is highlighted.
5. Open **Data Flow** for `total` to see the runtime value history and the AST
   sources that fed each change. Click any node to jump to its line.
6. Open **Experiments** → **New experiment**, name it, and keep the recorded
   baseline. Stateglass copies the project into its own data directory and opens
   the copy.
7. Edit `pricing.py` in the copy: change
   `tax = round(subtotal * TAX_RATE, 2)` to `tax = round(discounted * TAX_RATE, 2)`.
8. Run the experiment. Then open **Compare** to see output divergence, duration and
   memory deltas, the full diff, and which variables changed. The original folder
   still contains the buggy code.

Keyboard shortcuts are available from the keyboard icon in the header.

---

## Architecture

Stateglass is a native macOS app built with SwiftUI and Swift 6. Existing debugging
workflows still use the Rust sidecar and its versioned JSON-lines protocol. The
SoloVibe canvas is the first Python-owned feature slice: SwiftUI sends versioned
JSON-lines requests to a Python service, which persists context nodes and
dependencies in local SQLite. This is a staged migration; the Rust sidecar remains
required for the existing editor, execution, tracing, and experiment workflows.
The canvas and debugger currently use separate local databases.

```mermaid
flowchart LR
    subgraph Desktop["macOS app"]
        UI["SwiftUI + Swift 6"]
        IPC["JSON-lines sidecar protocol"]
        subgraph Rust["Rust sidecar"]
            CMD[command services]
            PM[project manager]
            EX[execution engine]
            TR[tracing engine]
            XP[experiment manager]
            ST[(SQLite storage)]
        end
    end

    subgraph Py["Python child process"]
        T["stateglass_tracer.py<br/>run + AST analyze"]
        P["user program"]
        CS["SoloVibe canvas service"]
        CST[(Canvas SQLite)]
    end

    UI -->|request / response| IPC --> CMD
    CMD --> PM
    CMD --> EX
    CMD --> TR
    CMD --> XP
    PM --> ST
    TR --> ST
    XP --> ST
    EX -->|spawn, stdin, timeout, kill| T
    T -->|trace NDJSON file| EX
    EX -->|stdout/stderr chunks, trace batches, status| IPC --> UI
    T -->|imports| P
    T -->|AST metadata JSON| XP
    UI -->|canvas JSON-lines request / response| CS
    CS --> CST
```

### Rust modules

| Module | Responsibility |
| --- | --- |
| `src-tauri/src/project.rs` | Open/import folders, ignore rules, entry-point detection, safe path resolution, text read/write, bundled sample |
| `src-tauri/src/execution.rs` | Child-process lifecycle, streaming pipes, timeout and process-group cleanup, resource sampling, trace-file tailing, event emission |
| `src-tauri/src/tracing.rs` | NDJSON framing/parsing, variable history queries and data-flow graph construction |
| `src-tauri/src/experiments.rs` | Recursive project copying, experiment creation, unified diffing, variable comparison, warnings |
| `src-tauri/src/storage.rs` | SQLite schema, migrations and all persistence queries |
| `src-tauri/src/python.rs` | Interpreter discovery/validation, tracer location, AST analysis orchestration |
| `src-tauri/src/watchers.rs` | Debounced filesystem notifications for open workspaces |
| `src-tauri/src/commands.rs` | Validates and delegates backend commands; exposes reusable service functions |
| `src-tauri/src/sidecar.rs` | JSON-lines method dispatch for the Swift app |
| `src-tauri/src/bin/stateglass-sidecar.rs` | Sidecar process, request responses, and streamed event transport |
| `src-tauri/src/models.rs` | Serializable DTOs (serde `camelCase`) shared across process boundary |
| `python/solovibe/` | Local canvas service, domain persistence, and versioned request dispatch |

### Native app modules

| Path | Responsibility |
| --- | --- |
| `xcode/Sources/StateGlass/StateGlassApp.swift` | Native app lifecycle and menu keyboard shortcuts |
| `xcode/Sources/StateGlass/ContentView.swift` | SwiftUI project workspace, editor, trace inspector, flow, experiment, compare, and console panels |
| `xcode/Sources/StateGlass/AppModel.swift` | Main-actor application state and backend workflows |
| `xcode/Sources/StateGlass/SidecarClient.swift` | Typed asynchronous JSON-lines transport, process lifecycle, and event stream |
| `xcode/Sources/StateGlass/Models.swift` | Swift DTOs corresponding to Rust serde models |
| `xcode/Sources/StateGlass/CanvasView.swift` | Native context-node canvas and dependency map |
| `xcode/Sources/StateGlass/CanvasBackendClient.swift` | Python canvas service transport |
| `xcode/Sources/StateGlass/CanvasModels.swift` | Typed context nodes, dependencies, and canvas state |

### IPC surface

The Swift client sends one JSON object per line with `protocolVersion` (currently
`1`), `id`, `method`, and `params`. Responses echo the protocol version and
request ID and contain either `result` or a typed `error`. Unsolicited event
messages use the same versioned stream and carry `event` and `payload` fields.
Long-running executions return immediately and stream output,
trace batches, metrics, completion, and workspace changes.

The Python canvas service uses the same versioned request/response envelope and
supports `list_canvas`, `add_node`, `update_node`, `add_dependency`, and
`remove_dependency`. Its database defaults to
`~/Library/Application Support/dev.solovibe.app/solovibe.sqlite3`; set
`SOLOVIBE_DATA_DIR` to override the containing directory.

**Commands:** `bootstrap`, `list_projects`, `open_project`, `create_sample_project`,
`get_project`, `update_project_config`, `set_project_consent`, `list_files`,
`read_file`, `write_file`, `analyze_workspace`, `start_run`, `cancel_run`,
`list_sessions`, `get_session`, `get_session_output`, `list_trace_events`,
`trace_stats`, `variables_at`, `variable_history`, `data_flow`,
`create_experiment`, `list_experiments`, `compare_sessions`,
`list_python_runtimes`, `set_global_python_path`.

**Events:** `run:output`, `run:trace`, `run:stats`, `run:finished`,
`workspace:changed`.

---

## How tracing works

[`python/stateglass_tracer.py`](python/stateglass_tracer.py) has no third-party
dependencies. It has two modes:

### `run`

```
python3 stateglass_tracer.py run \
  --trace-file <session>.ndjson --root <project> \
  --events-limit 200000 --value-limit 180 \
  --max-depth 40 --max-locals 64 -- <entry>.py [args...]
```

- Installs `sys.settrace` (and `threading.settrace`) and traces frames whose real
  path is inside the project root, skipping the standard library, site-packages
  and the helper itself.
- Emits newline-delimited JSON events (see below) and runs the entry file with
  `runpy.run_path(..., run_name="__main__")`.
- Program stdout/stderr are **not** used for tracing, so the application's output
  remains untouched.
- Exceptions are reported and the process exits with a non-zero code; `SystemExit`
  codes are preserved.
- Event volume is capped. On overflow a `truncated` event is emitted and tracing
  stops while the program continues.

### `analyze`

Parses Python files with `ast` and prints assignment metadata:

```json
{
  "files": [{
    "file": "pricing.py",
    "assignments": [{
      "line": 39, "col": 4, "func": "compute_order_total",
      "target": "tax", "sources": ["subtotal", "TAX_RATE"],
      "callee": "round", "kind": "assign"
    }],
    "functions": [{ "line": 24, "name": "compute_order_total", "kind": "function" }],
    "errors": []
  }]
}
```

Handled constructs include normal/annotated/augmented assignment, `for`, `with`,
walrus expressions, tuple targets, attributes (`self.total`) and subscript targets.
Syntax errors are reported per file and never crash the app.

### Event protocol

| Kind | Meaning | Key fields |
| --- | --- | --- |
| `session_start` | Tracer started | `root`, `entry`, `argv`, `python` |
| `call` | Function entered | `frame`, `parent`, `depth`, `file`, `line`, `func` |
| `line` | Source line about to execute | `frame`, `file`, `line`, `func` |
| `var` | Local value created/changed | `frame`, `name`, `value`, `vtype`, `file`, `line`, `func` |
| `return` | Function exited | `frame`, `file`, `line`, `func`, `value`, `vtype` |
| `exception` | Unhandled or handled exception | `vtype`, `value`, `file`, `line` |
| `truncated` | Event budget exhausted | `limit`, `events` |
| `session_end` | Footer | `status`, `exit_code`, `error`, `duration_ms`, `truncated` |

All events also carry monotonically increasing `seq` and epoch-millisecond `ts`.

**Line attribution:** Python fires a `line` event *before* executing that line, so
a change is observed at the next line event. Stateglass attributes the change to
the previously executed line, which matches the assignment that produced it. This
is covered by tests.

### Safe value capture

Values are never pickled or blindly serialized:

- primitives are `repr`-limited to a configurable length;
- lists/tuples/dicts/sets are rendered shallowly (max 12 items, depth 2, cycle-safe,
  sets sorted for stability);
- arbitrary objects become `<ClassName>` so memory addresses do not leak into diffs;
- frames are capped by depth and number of locals, and dunder names are skipped.

`repr()` of a user object can execute user code — exactly like a conventional
debugger. This is documented rather than hidden.

### Known trace limitations

- C extensions, native calls and subinterpreters are not traced.
- Child processes (e.g. `multiprocessing`) are not instrumented (new threads are).
- Global variables mutated inside functions are observed when the module frame next
  samples its locals; local variables are sampled per line.
- Sampling is line-granular, not every bytecode write.
- Traces are capped at 200,000 events by default.
- Instrumentation slows execution; comparisons include that overhead.

---

## How data flow is built

Data flow is **inferred**, never fabricated:

1. The AST analyzer records every assignment site with the names it reads.
2. The runtime records each variable change with `file`, `line`, `func` and `seq`.
3. For the selected variable, Stateglass takes its most recent 24 changes and
   matches each to a static assignment in the same file/function/line (falling back
   to the nearest preceding assignment in that function).
4. For each matched source name, the most recent earlier runtime snapshot of that
   name is found and connected as an edge labelled with the source name.
5. Consecutive changes of the target are connected with `update` edges.

The response includes `assignmentSites` with a `matched` flag, so the UI can be
honest about which edges came from AST metadata and which are runtime-only. When
analysis is unavailable, the graph still shows the runtime history with a note.

---

## Experiments and comparison

Creating an experiment:

- saves any unsaved editor buffers, then validates that the baseline belongs to the
  project, is a baseline, and has finished;
- copies every non-ignored file (no `.git`, virtualenvs, caches, build output) to
  `<app-data>/experiments/<id>/project`; the copy reflects the project's current
  on-disk state;
- writes `experiment.json` metadata next to the copy;
- analyzes the copy separately, so the copy's own assignments power its data flow;
- registers the experiment in SQLite. Nothing is deleted afterwards.

Running an experiment:

- reuses the baseline's **entry file, arguments, stdin, timeout and interpreter**
  (falling back to the newest supported interpreter if the recorded one is gone);
- runs in the copy's directory with a new session id, trace file and output;
- captures the same metrics as a baseline run.

Comparison shows:

- status, exit code, duration and peak memory for each side;
- a line diff of stdout and stderr (with context around changes);
- final value of every variable present in either trace, marked
  `same`/`changed`/`added`/`removed`;
- the first stdout divergence line;
- explicit warnings about replay fidelity, truncation, status differences and
  error messages.

**Replay is not guaranteed to be identical.** External services, databases,
clocks, randomness, filesystem state, network access and instrumentation overhead
can change results. The UI says so in every comparison.

---

## Persistence and local data

SQLite database: `<app-data>/stateglass.sqlite3`.

The macOS app data directory is `~/Library/Application Support/dev.stateglass.app/`.

Tables: `projects`, `sessions`, `trace_events`, `assignments`, `experiments`,
`settings`. Trace files are kept as NDJSON under `<app-data>/traces/`; experiment
copies live under `<app-data>/experiments/`; the bundled sample is copied to
`<app-data>/samples/python-demo`.

Stored stdout/stderr are capped at 3 MB per stream; trace events at 200k per
session. The database keeps run history across restarts.

---

## Security, limits and honest caveats

- **Not a sandbox.** Project code runs as a child process with your user
  privileges. There is no container, namespace or VM isolation. Consent is required
  once per project before the first run.
- **Process cleanup.** On Unix the child starts in its own process group; timeout
  and cancellation send `SIGKILL` to the group. On Windows `taskkill /T /F` is used.
  Descendants that deliberately detach can still escape cleanup.
- **Timeouts** default to 20 s and are clamped to 1–600 s. Timeout is reported as
  `timeout` and the session records the reason.
- **No network calls** are made by Stateglass itself. Project code may make its own.
- **File boundaries.** Backend file operations reject absolute paths, `..`
  traversal and canonicalized paths outside the active workspace root. Experiments
  are always copies.
- **Trace file size** grows with executed lines; limits bound memory, DB size and
  UI work.
- **Local only.** No accounts, paid APIs, AI features or language models.

---

## Testing

```bash
npm test
```

Coverage highlights:

- Rust unit + integration tests (spawns real Python helper processes), including
  sidecar command dispatch and protocol errors;
- Swift 6 native app compilation;
- Python tracer and analyzer tests;
- storage CRUD, trace queries, variable snapshots, history ordering;
- path traversal and binary-file rejection;
- project copy isolation (original file unchanged after editing the copy);
- end-to-end traced execution with real Python: variable history, stdout, peak
  memory, event streaming;
- timeout enforcement against an infinite loop;
- experiment creation, replay, output divergence, variable comparison, preserved
  history, data-flow construction;
- Python summarization safety, line attribution, event limits, error reporting,
  AST dependencies, stdlib frame exclusion;
- NDJSON framing across partial chunks;
- JSON request/response transport and streamed output, trace, and watcher events.

Integration tests skip nothing — they require Python 3.11+ to be installed.

---

## Repository layout

```
.
├── README.md
├── package.json               Native dev/build/test entry points
├── xcode/
│   ├── Package.swift          Swift 6 macOS executable package
│   └── Sources/StateGlass/    SwiftUI app, state, canvas, and backend clients
├── scripts/                   Native development, build, and test scripts
├── src-tauri/
│   ├── src/                   Rust backend, sidecar protocol, and adapters
│   ├── tests/                 End-to-end execution/experiment tests
│   ├── examples/seed_demo.rs  Developer data seeding utility
│   └── Cargo.toml             Rust backend and sidecar targets
├── python/
│   ├── stateglass_tracer.py   Runtime instrumentation + AST analyzer
│   ├── solovibe/              Local-first canvas service and SQLite store
│   └── tests/                 unittest suite
├── samples/python-demo/       Buggy pricing pipeline used in demos/tests
├── src/                       Retained legacy web UI sources
└── scripts/gen_icons.py       Dependency-free icon generator
```

---

## Extending to other languages

Only Python is implemented. The boundaries that keep this maintainable:

- `execution.rs` only knows how to spawn an interpreter with an entry file, stream
  its output, enforce timeouts and tail an NDJSON event file.
- `RawTraceEvent` / `TraceEvent` are a small, language-neutral event vocabulary
  (call, line, var, return, exception, end).
- `assignments` are language-neutral records of `target` + `sources` per line and
  function. A new language needs an analyzer that emits the same shape.
- Sessions store the interpreter path and command-line arguments as data, not code.

A future language adapter would add: entry-point detection, interpreter discovery,
a tracer/analyzer helper implementing the event and analysis schemas, and a language
mode in the native editor. The existing timeline and comparison models consume the
language-neutral event and assignment schemas.

---

## Development utilities

`src-tauri/examples/seed_demo.rs` populates a database with a real baseline and a
real experiment for the sample project (useful for demos, documentation and manual
QA):

```bash
cd src-tauri
cargo run --example seed_demo -- ../samples/python-demo \
  "$HOME/Library/Application Support/dev.stateglass.app"
```

`scripts/gen_icons.py` regenerates all app icons without external image libraries.

---

## Troubleshooting

**“No Python 3.11+ interpreter was found.”**
Install Python 3.11+, add it to `PATH`, or set an interpreter per project in Run
settings. Project `.venv/bin/python` (and `Scripts/python.exe`) are detected.

**“The Python instrumentation helper is missing.”**
In development the helper is resolved from `python/stateglass_tracer.py`; in the
app bundle it is included under `Contents/Resources/python`. Reinstall or set `STATEGLASS_TRACER` to
an absolute path.

**A run times out.**
Increase the timeout in Run settings. Timeouts kill the process group and are
recorded as `timeout`, not as a trace error.

**Data-flow edges are missing.**
Run **re-analyze** (refresh icon in the header). Large files (>512 KB), generated
code or dynamic constructs may not produce AST metadata; the graph note will say so.

**Output is truncated.**
Per-stream output is capped at 3 MB and traces at 200k events. This is deliberate
to keep the app responsive.

**The Swift app does not build.**
Use macOS 14 or newer and Xcode with Swift 6, then run `swift build --package-path xcode`.

---

## Non-goals

- No security sandbox or remote execution.
- No cloud accounts, collaboration, telemetry or paid APIs.
- No AI features or local language models.
- No claim that a replay is byte-for-byte reproducible.
- No support for every language in the first version.
