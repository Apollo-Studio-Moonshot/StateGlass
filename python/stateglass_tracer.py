#!/usr/bin/env python3
"""Stateglass Python instrumentation helper.

Stateglass keeps Python introspection in a separate helper process so the Rust
backend only has to consume a simple, structured event stream.

Two commands:

  run
      Execute a Python program with ``sys.settrace`` instrumentation and append
      newline-delimited JSON events to ``--trace-file``.

  analyze
      Parse one or more Python files with the ``ast`` module and print a JSON
      description of assignments plus the names each assignment reads. This is
      used to connect runtime variable states into a data-flow graph.

Safety notes
------------
* Values are never serialized with arbitrary pickle/JSON encoders. Only short,
  human-readable summaries of primitives and shallow containers are captured.
* ``repr()`` of user objects can execute user code, exactly like a normal
  debugger. Instrumentation therefore runs with the same privileges as the
  traced program; this is *not* a sandbox.
* Event volume is capped. When the cap is reached tracing is disabled and a
  ``truncated`` event is emitted.
"""

from __future__ import annotations

import ast
import json
import os
import runpy
import sys
import threading
import time
import traceback
import types as _types
from typing import Any, Iterable

DEFAULT_EVENT_LIMIT = 200_000
DEFAULT_VALUE_LIMIT = 180
DEFAULT_MAX_DEPTH = 40
DEFAULT_MAX_LOCALS = 64
MAX_CONTAINER_ITEMS = 12
TYPES_MODULE = _types.ModuleType
TYPES_FUNCTION = _types.FunctionType
TYPES_METHOD = _types.MethodType
SKIPPED_DIRS = (
    "/site-packages/",
    "/dist-packages/",
    "/lib/python",
    "/src-tauri/",
    "/node_modules/",
    "/__pycache__/",
)


# ---------------------------------------------------------------------------
# Value summarization
# ---------------------------------------------------------------------------


def _truncate(text: str, limit: int) -> str:
    if limit <= 0:
        return ""
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 1)] + "…"


def _container_preview(value: Any, limit: int, depth: int, seen: set[int]) -> str:
    if depth > 2:
        return "…"
    if id(value) in seen:
        return "…"
    seen.add(id(value))
    try:
        if isinstance(value, dict):
            parts = []
            for index, (key, item) in enumerate(value.items()):
                if index >= MAX_CONTAINER_ITEMS:
                    parts.append("…")
                    break
                parts.append(
                    f"{_summarize(key, limit, depth + 1, seen)[0]}: "
                    f"{_summarize(item, limit, depth + 1, seen)[0]}"
                )
            return _truncate("{" + ", ".join(parts) + "}", limit)
        if isinstance(value, (set, frozenset)):
            rendered = sorted(
                _summarize(item, 40, depth + 1, seen)[0] for item in value
            )
            parts = rendered[:MAX_CONTAINER_ITEMS]
            if len(rendered) > MAX_CONTAINER_ITEMS:
                parts.append("…")
            body = ", ".join(parts)
            if isinstance(value, frozenset):
                return _truncate("frozenset({" + body + "})", limit)
            return _truncate("{" + body + "}", limit) if body else "set()"
        items = []
        for index, item in enumerate(value):
            if index >= MAX_CONTAINER_ITEMS:
                items.append("…")
                break
            items.append(_summarize(item, limit, depth + 1, seen)[0])
        body = ", ".join(items)
        if isinstance(value, list):
            return _truncate("[" + body + "]", limit)
        if isinstance(value, tuple):
            single = "," if len(value) == 1 else ""
            return _truncate("(" + body + single + ")", limit)
    finally:
        seen.discard(id(value))
    return _truncate(repr(value), limit)


def _summarize(value: Any, limit: int = DEFAULT_VALUE_LIMIT, depth: int = 0, seen: set[int] | None = None) -> tuple[str, str]:
    """Return ``(display_text, type_name)`` without ever raising."""
    seen = set() if seen is None else seen
    try:
        type_name = type(value).__name__
        if value is None:
            return "None", "NoneType"
        if isinstance(value, bool):
            return repr(value), "bool"
        if isinstance(value, (int, float, complex, str, bytes, bytearray)):
            return _truncate(repr(value), limit), type_name
        if isinstance(value, (list, tuple, set, frozenset, dict)):
            return _container_preview(value, limit, depth, seen), type_name
        if isinstance(value, type):
            return f"<class {value.__name__}>", "type"
        if isinstance(value, TYPES_MODULE):
            return f"<module '{value.__name__}'>", "module"
        if isinstance(value, TYPES_FUNCTION):
            name = getattr(value, "__qualname__", None) or getattr(value, "__name__", "?")
            return f"<function {name}>", "function"
        if isinstance(value, TYPES_METHOD):
            name = getattr(value, "__name__", "?")
            return f"<method {name}>", "method"
        # Deliberately avoid default reprs that embed memory addresses.
        return f"<{type_name}>", type_name
    except BaseException:
        try:
            return "<unrepresentable>", type(value).__name__
        except BaseException:
            return "<unrepresentable>", "unknown"


# ---------------------------------------------------------------------------
# Event emitter
# ---------------------------------------------------------------------------


class Emitter:
    def __init__(self, path: str, flush_every: int = 1) -> None:
        self._fh = open(path, "w", encoding="utf-8", buffering=1)
        self._lock = threading.RLock()
        self._flush_every = max(1, flush_every)
        self._since_flush = 0
        self.seq = 0
        self.count = 0

    def emit(self, kind: str, **fields: Any) -> None:
        with self._lock:
            self.seq += 1
            event: dict[str, Any] = {
                "seq": self.seq,
                "ts": int(time.time() * 1000),
                "kind": kind,
            }
            for key, value in fields.items():
                if value is not None:
                    event[key] = value
            try:
                self._fh.write(json.dumps(event, ensure_ascii=False, default=str) + "\n")
            except BaseException:
                return
            self.count += 1
            self._since_flush += 1
            if self._since_flush >= self._flush_every:
                self._since_flush = 0
                try:
                    self._fh.flush()
                except BaseException:
                    pass

    def close(self) -> None:
        with self._lock:
            try:
                self._fh.flush()
                self._fh.close()
            except BaseException:
                pass


# ---------------------------------------------------------------------------
# Tracer
# ---------------------------------------------------------------------------


class FrameState:
    __slots__ = ("id", "locals", "last_line", "file", "func", "is_generator")

    def __init__(self, frame_id: int, file: str, func: str, is_generator: bool) -> None:
        self.id = frame_id
        self.locals: dict[str, tuple[str, str]] = {}
        self.last_line = 0
        self.file = file
        self.func = func
        self.is_generator = is_generator


class Tracer:
    def __init__(
        self,
        emitter: Emitter,
        root: str,
        event_limit: int,
        value_limit: int,
        max_depth: int,
        max_locals: int,
        line_events: bool = True,
        tracer_path: str | None = None,
    ) -> None:
        self.emitter = emitter
        self.root = os.path.realpath(root)
        if not self.root.endswith(os.sep):
            self.root_prefix = self.root + os.sep
        else:
            self.root_prefix = self.root
        self.event_limit = event_limit
        self.value_limit = value_limit
        self.max_depth = max_depth
        self.max_locals = max_locals
        self.line_events = line_events
        self.tracer_path = os.path.realpath(tracer_path) if tracer_path else None
        self.frames: dict[int, FrameState] = {}
        self._next_id = 1
        self._lock = threading.RLock()
        self._scope_cache: dict[str, bool] = {}
        self._disabled = False
        self._truncated = False
        self.trace_events = 0

    # -- scope -------------------------------------------------------------

    def in_scope(self, filename: str) -> bool:
        cached = self._scope_cache.get(filename)
        if cached is not None:
            return cached
        result = False
        try:
            if filename and not filename.startswith("<"):
                real = os.path.realpath(filename)
                if self.tracer_path and real == self.tracer_path:
                    result = False
                elif real == self.root or real.startswith(self.root_prefix):
                    lowered = "/" + real.replace(os.sep, "/")
                    result = not any(marker in lowered for marker in SKIPPED_DIRS)
        except BaseException:
            result = False
        self._scope_cache[filename] = result
        return result

    # -- event helpers -----------------------------------------------------

    def _budget_left(self) -> bool:
        if self._disabled:
            return False
        if self.trace_events >= self.event_limit:
            self._disable()
            return False
        return True

    def _disable(self) -> None:
        if self._truncated:
            return
        self._truncated = True
        self._disabled = True
        try:
            self.emitter.emit(
                "truncated",
                message=(
                    "Trace event limit reached; execution continued without "
                    "further instrumentation."
                ),
                limit=self.event_limit,
                events=self.trace_events,
            )
        except BaseException:
            pass

    def _emit(self, kind: str, **fields: Any) -> None:
        if self._disabled:
            return
        self.emitter.emit(kind, **fields)
        self.trace_events += 1

    # -- trace hooks -------------------------------------------------------

    def global_trace(self, frame, event, arg):  # noqa: ANN001
        try:
            if event != "call":
                return self.local_trace
            if self._disabled:
                return None
            filename = frame.f_code.co_filename
            if not self.in_scope(filename):
                return None
            with self._lock:
                depth = len(self.frames)
                if depth >= self.max_depth:
                    return None
                if not self._budget_left():
                    return None
                state = self._new_frame(frame)
            self._emit(
                "call",
                frame=state.id,
                parent=self._parent_id(frame),
                depth=depth,
                file=state.file,
                line=frame.f_lineno,
                func=state.func,
            )
            self._snapshot(frame, state, executed_line=frame.f_lineno)
            return self.local_trace
        except BaseException:
            return None

    def local_trace(self, frame, event, arg):  # noqa: ANN001
        try:
            if self._disabled:
                return None
            with self._lock:
                state = self.frames.get(id(frame))
            if state is None:
                return self.local_trace
            if event == "line":
                if self.line_events:
                    self._emit(
                        "line",
                        frame=state.id,
                        file=state.file,
                        line=frame.f_lineno,
                        func=state.func,
                    )
                self._snapshot(frame, state, executed_line=state.last_line or frame.f_lineno)
                state.last_line = frame.f_lineno
            elif event == "return":
                self._snapshot(frame, state, executed_line=state.last_line or frame.f_lineno)
                value, vtype = ("", "")
                if not state.is_generator:
                    value, vtype = _summarize(arg, self.value_limit)
                self._emit(
                    "return",
                    frame=state.id,
                    file=state.file,
                    line=state.last_line or frame.f_lineno,
                    func=state.func,
                    value=value,
                    vtype=vtype,
                )
                with self._lock:
                    self.frames.pop(id(frame), None)
            elif event == "exception":
                exc_type, exc_value = arg[0], arg[1]
                name = getattr(exc_type, "__name__", "Exception")
                if name in ("StopIteration", "GeneratorExit"):
                    return self.local_trace
                self._emit(
                    "exception",
                    file=state.file,
                    line=frame.f_lineno,
                    func=state.func,
                    vtype=name,
                    value=_truncate(str(exc_value), self.value_limit),
                )
        except BaseException:
            pass
        return self.local_trace

    # -- frame bookkeeping -------------------------------------------------

    def _new_frame(self, frame) -> FrameState:  # noqa: ANN001
        code = frame.f_code
        func = getattr(code, "co_qualname", None) or code.co_name
        is_generator = bool(code.co_flags & 0x20)
        state = FrameState(self._next_id, code.co_filename, func, is_generator)
        self._next_id += 1
        self.frames[id(frame)] = state
        return state

    def _parent_id(self, frame) -> int | None:  # noqa: ANN001
        back = frame.f_back
        while back is not None:
            state = self.frames.get(id(back))
            if state is not None:
                return state.id
            back = back.f_back
        return None

    def _snapshot(self, frame, state: FrameState, executed_line: int) -> None:  # noqa: ANN001
        if self._disabled:
            return
        try:
            items = list(frame.f_locals.items())
        except BaseException:
            return
        current: dict[str, tuple[str, str]] = {}
        changed: list[tuple[str, str, str]] = []
        present: set[str] = set()
        for name, _value in items:
            if name.startswith("__") and name.endswith("__"):
                continue
            present.add(name)
        for index, (name, value) in enumerate(items):
            if index >= self.max_locals:
                break
            if name.startswith("__") and name.endswith("__"):
                continue
            text, vtype = _summarize(value, self.value_limit)
            current[name] = (vtype, text)
            if state.locals.get(name) != (vtype, text):
                changed.append((name, text, vtype))
        for name, text, vtype in changed:
            if not self._budget_left():
                state.locals = current
                return
            self._emit(
                "var",
                frame=state.id,
                file=state.file,
                line=executed_line,
                func=state.func,
                name=name,
                value=text,
                vtype=vtype,
                changed=True,
            )
        # Tombstone locals that disappeared from the frame (``del x`` or a
        # rebinding scope) so inspectors stop showing values that are gone.
        for name in state.locals:
            if name in present:
                continue
            if not self._budget_left():
                break
            self._emit(
                "del",
                frame=state.id,
                file=state.file,
                line=executed_line,
                func=state.func,
                name=name,
            )
        state.locals = current


# ---------------------------------------------------------------------------
# AST analysis
# ---------------------------------------------------------------------------


def _attribute_text(node: ast.AST) -> str | None:
    parts: list[str] = []
    current = node
    while isinstance(current, ast.Attribute):
        parts.append(current.attr)
        current = current.value
    if isinstance(current, ast.Name):
        parts.append(current.id)
        return ".".join(reversed(parts))
    if isinstance(current, ast.Call):
        inner = _attribute_text(current.func)
        if inner is None:
            return None
        suffix = ".".join(reversed(parts))
        return f"{inner}().{suffix}" if suffix else f"{inner}()"
    return None


def _expr_names(node: ast.AST | None, limit: int = 24) -> list[str]:
    if node is None:
        return []
    names: list[str] = []

    def add(name: str) -> None:
        if name and name not in names and len(names) < limit:
            names.append(name)

    def walk(current: ast.AST | None) -> None:
        if current is None or len(names) >= limit:
            return
        if isinstance(current, ast.Name):
            add(current.id)
        elif isinstance(current, ast.Attribute):
            text = _attribute_text(current)
            if text is not None:
                add(text)
            else:
                walk(current.value)
        elif isinstance(current, ast.Subscript):
            walk(current.value)
            walk(current.slice)
        elif isinstance(current, ast.Call):
            walk(current.func)
            for arg in current.args:
                walk(arg)
            for keyword in current.keywords:
                walk(keyword.value)
        elif isinstance(current, ast.Lambda):
            return
        elif isinstance(current, (ast.ListComp, ast.SetComp, ast.GeneratorExp, ast.DictComp)):
            for generator in current.generators:
                walk(generator.iter)
        else:
            for child in ast.iter_child_nodes(current):
                walk(child)

    walk(node)
    return [name for name in names if name != "self"]


def _callee_name(node: ast.AST | None) -> str | None:
    if isinstance(node, ast.Call):
        return _attribute_text(node.func) or (node.func.id if isinstance(node.func, ast.Name) else None)
    return None


def _target_names(targets: Iterable[ast.AST]) -> list[tuple[str, str]]:
    resolved: list[tuple[str, str]] = []

    def walk(node: ast.AST | None) -> None:
        if node is None:
            return
        if isinstance(node, ast.Name):
            resolved.append((node.id, "name"))
        elif isinstance(node, ast.Attribute):
            text = _attribute_text(node)
            if text:
                resolved.append((text, "attribute"))
        elif isinstance(node, ast.Subscript):
            text = _attribute_text(node.value)
            if text:
                resolved.append((f"{text}[…]", "subscript"))
        elif isinstance(node, (ast.Tuple, ast.List)):
            for element in node.elts:
                walk(element)
        elif isinstance(node, ast.Starred):
            walk(node.value)

    for target in targets:
        walk(target)
    return resolved


class _Analyzer(ast.NodeVisitor):
    def __init__(self) -> None:
        self.scope: list[str] = ["<module>"]
        self.assignments: list[dict[str, Any]] = []
        self.functions: list[dict[str, Any]] = []
        self._seen: set[tuple[int, int, str]] = set()

    def _qualname(self) -> str:
        # ``co_qualname`` for top-level definitions is just ``name``, so the
        # synthetic <module> scope is dropped here to keep runtime events and
        # static analysis records joinable.
        return ".".join(self.scope[1:]) or "<module>"

    def _record(
        self,
        *,
        line: int,
        col: int,
        target: str,
        sources: list[str],
        kind: str,
        callee: str | None = None,
    ) -> None:
        key = (line, col, target)
        if key in self._seen:
            return
        self._seen.add(key)
        self.assignments.append(
            {
                "line": line,
                "col": col,
                "func": self._qualname(),
                "target": target,
                "sources": sources,
                "callee": callee,
                "kind": kind,
            }
        )

    def _visit_function(self, node: ast.AST) -> None:
        name = getattr(node, "name", "?")
        qualname = ".".join(self.scope[1:] + [name])
        self.functions.append(
            {
                "line": getattr(node, "lineno", 0),
                "name": name,
                "qualname": qualname,
                "kind": "class" if isinstance(node, ast.ClassDef) else "function",
            }
        )
        self.scope.append(name)
        self.generic_visit(node)
        self.scope.pop()

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        self._visit_function(node)

    def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
        self._visit_function(node)

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        self._visit_function(node)

    def visit_Assign(self, node: ast.Assign) -> None:
        sources = _expr_names(node.value)
        callee = _callee_name(node.value)
        for target, _kind in _target_names(node.targets):
            self._record(
                line=node.lineno,
                col=node.col_offset,
                target=target,
                sources=sources,
                callee=callee,
                kind="assign",
            )
        self.generic_visit(node)

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        if node.value is not None:
            sources = _expr_names(node.value)
            callee = _callee_name(node.value)
            for target, _kind in _target_names([node.target]):
                self._record(
                    line=node.lineno,
                    col=node.col_offset,
                    target=target,
                    sources=sources,
                    callee=callee,
                    kind="assign",
                )
        self.generic_visit(node)

    def visit_AugAssign(self, node: ast.AugAssign) -> None:
        sources = _expr_names(node.value)
        for target, _kind in _target_names([node.target]):
            self._record(
                line=node.lineno,
                col=node.col_offset,
                target=target,
                sources=[target, *[s for s in sources if s != target]],
                kind="augassign",
            )
        self.generic_visit(node)

    def visit_For(self, node: ast.For) -> None:
        sources = _expr_names(node.iter)
        for target, _kind in _target_names([node.target]):
            self._record(
                line=node.lineno,
                col=node.col_offset,
                target=target,
                sources=sources,
                kind="for",
            )
        self.generic_visit(node)

    def visit_AsyncFor(self, node: ast.AsyncFor) -> None:
        self.visit_For(node)  # type: ignore[arg-type]

    def visit_With(self, node: ast.With) -> None:
        for item in node.items:
            if item.optional_vars is None:
                continue
            sources = _expr_names(item.context_expr)
            for target, _kind in _target_names([item.optional_vars]):
                self._record(
                    line=node.lineno,
                    col=node.col_offset,
                    target=target,
                    sources=sources,
                    kind="with",
                )
        self.generic_visit(node)

    def visit_NamedExpr(self, node: ast.NamedExpr) -> None:
        sources = _expr_names(node.value)
        for target, _kind in _target_names([node.target]):
            self._record(
                line=node.lineno,
                col=node.col_offset,
                target=target,
                sources=sources,
                kind="walrus",
            )
        self.generic_visit(node)


def analyze_files(files: list[str], value_limit: int = 200) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    for path in files:
        entry: dict[str, Any] = {"file": path, "assignments": [], "functions": [], "errors": []}
        try:
            with open(path, "rb") as handle:
                raw = handle.read(2_000_000)
            source = raw.decode("utf-8", errors="replace")
            tree = ast.parse(source, filename=path)
            analyzer = _Analyzer()
            analyzer.visit(tree)
            entry["assignments"] = analyzer.assignments
            entry["functions"] = analyzer.functions
        except SyntaxError as exc:
            entry["errors"].append(f"{exc.msg} (line {exc.lineno})")
        except BaseException as exc:  # noqa: BLE001 - analysis must never crash the app
            entry["errors"].append(f"{type(exc).__name__}: {exc}")
        results.append(entry)
    return {"files": results, "valueLimit": value_limit}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_flags(argv: list[str]) -> tuple[dict[str, str | None], list[str]]:
    """Split ``--flag value``/``--flag=value`` pairs from positional arguments."""
    flags: dict[str, str | None] = {}
    positional: list[str] = []
    index = 0
    while index < len(argv):
        token = argv[index]
        if token == "--":
            positional.extend(argv[index + 1 :])
            break
        if token.startswith("--"):
            name = token[2:]
            if "=" in name:
                key, value = name.split("=", 1)
                flags[key] = value
            else:
                value: str | None = None
                if index + 1 < len(argv) and not argv[index + 1].startswith("--"):
                    value = argv[index + 1]
                    index += 1
                flags[name] = value
        else:
            positional.append(token)
        index += 1
    return flags, positional


def run_command(argv: list[str]) -> int:
    flags, positional = parse_flags(argv)
    trace_file = flags.get("trace-file")
    root = flags.get("root") or os.getcwd()
    if not trace_file:
        print("[stateglass] missing --trace-file", file=sys.stderr)
        return 2
    if not positional:
        print("[stateglass] missing script after --", file=sys.stderr)
        return 2

    script = os.path.abspath(positional[0])
    script_args = positional[1:]
    try:
        event_limit = int(flags.get("events-limit") or DEFAULT_EVENT_LIMIT)
    except ValueError:
        event_limit = DEFAULT_EVENT_LIMIT
    try:
        value_limit = int(flags.get("value-limit") or DEFAULT_VALUE_LIMIT)
    except ValueError:
        value_limit = DEFAULT_VALUE_LIMIT
    try:
        max_depth = int(flags.get("max-depth") or DEFAULT_MAX_DEPTH)
    except ValueError:
        max_depth = DEFAULT_MAX_DEPTH
    try:
        max_locals = int(flags.get("max-locals") or DEFAULT_MAX_LOCALS)
    except ValueError:
        max_locals = DEFAULT_MAX_LOCALS
    line_events = flags.get("no-lines") is None

    os.makedirs(os.path.dirname(os.path.abspath(trace_file)), exist_ok=True)
    emitter = Emitter(trace_file)
    tracer = Tracer(
        emitter,
        root=os.path.abspath(root),
        event_limit=max(1000, event_limit),
        value_limit=max(20, value_limit),
        max_depth=max(1, max_depth),
        max_locals=max(1, max_locals),
        line_events=line_events,
        tracer_path=os.path.abspath(__file__),
    )
    emitter.emit(
        "session_start",
        root=os.path.abspath(root),
        entry=script,
        argv=[script, *script_args],
        python=sys.version.split()[0],
        executable=sys.executable,
    )

    sys.argv = [script, *script_args]
    sys.path.insert(0, os.path.dirname(script))
    status = "ok"
    exit_code = 0
    error: str | None = None
    started = time.time()

    sys.settrace(tracer.global_trace)
    threading.settrace(tracer.global_trace)
    try:
        runpy.run_path(script, run_name="__main__")
    except SystemExit as exc:  # noqa: PERF203
        code = exc.code
        if isinstance(code, int):
            exit_code = code
        elif code is None:
            exit_code = 0
        else:
            exit_code = 1
            error = str(code)
            status = "error"
            print(code, file=sys.stderr)
    except BaseException as exc:  # noqa: BLE001 - we report and exit cleanly
        status = "error"
        exit_code = 1
        error = f"{type(exc).__name__}: {exc}"
        traceback.print_exc()
    finally:
        sys.settrace(None)
        try:
            threading.settrace(None)
        except BaseException:
            pass
        if exit_code != 0 and status == "ok" and error is None:
            status = "error"

    emitter.emit(
        "session_end",
        status=status,
        exit_code=exit_code,
        error=error,
        duration_ms=int((time.time() - started) * 1000),
        events=tracer.trace_events,
        truncated=tracer._truncated,
    )
    emitter.close()
    return exit_code


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: stateglass_tracer.py run|analyze ...", file=sys.stderr)
        return 2
    command = argv[0]
    if command == "run":
        return run_command(argv[1:])
    if command == "analyze":
        files = [arg for arg in argv[1:] if not arg.startswith("--")]
        try:
            print(json.dumps(analyze_files(files), ensure_ascii=False))
        except BaseException as exc:  # noqa: BLE001
            print(f"[stateglass] analysis failed: {exc}", file=sys.stderr)
            return 1
        return 0
    print(f"[stateglass] unknown command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
