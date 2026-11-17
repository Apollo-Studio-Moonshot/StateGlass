"""Tests for the Stateglass Python instrumentation helper.

Run with: python3 -m unittest discover -s python/tests -v
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

TRACER_PATH = Path(__file__).resolve().parents[1] / "stateglass_tracer.py"
SPEC = importlib.util.spec_from_file_location("stateglass_tracer", TRACER_PATH)
tracer_module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(tracer_module)


def run_tracer(project_dir: Path, args: list[str] | None = None, timeout: float = 30.0) -> tuple[int, str, str]:
    command = [
        sys.executable,
        str(TRACER_PATH),
        "run",
        "--trace-file",
        str(project_dir / "trace.ndjson"),
        "--root",
        str(project_dir),
        "--",
        str(project_dir / "main.py"),
        * (args or []),
    ]
    completed = subprocess.run(
        command,
        cwd=str(project_dir),
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return completed.returncode, completed.stdout, completed.stderr


def read_events(project_dir: Path) -> list[dict]:
    events = []
    with open(project_dir / "trace.ndjson", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                events.append(json.loads(line))
    return events


class SummarizeTests(unittest.TestCase):
    def test_primitives(self) -> None:
        self.assertEqual(tracer_module._summarize(3), ("3", "int"))
        self.assertEqual(tracer_module._summarize("hi"), ("'hi'", "str"))
        self.assertEqual(tracer_module._summarize(None), ("None", "NoneType"))

    def test_containers_are_shallow_and_cycle_safe(self) -> None:
        value = [1, 2, 3]
        value.append(value)
        text, vtype = tracer_module._summarize(value)
        self.assertEqual(vtype, "list")
        self.assertIn("[1, 2, 3, …", text)

    def test_sets_are_sorted_for_stability(self) -> None:
        left = tracer_module._summarize({"b", "a", "c"})[0]
        right = tracer_module._summarize({"c", "b", "a"})[0]
        self.assertEqual(left, right)
        self.assertEqual(left, "{'a', 'b', 'c'}")

    def test_objects_avoid_memory_addresses(self) -> None:
        class Thing:
            pass

        text, vtype = tracer_module._summarize(Thing())
        self.assertEqual(vtype, "Thing")
        self.assertEqual(text, "<Thing>")

    def test_long_values_are_truncated(self) -> None:
        text, _ = tracer_module._summarize("x" * 500, limit=20)
        self.assertLessEqual(len(text), 20)
        self.assertTrue(text.endswith("…"))


class RunTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        (self.root / "helper.py").write_text(
            textwrap.dedent(
                """
                def tax(subtotal):
                    rate = 0.1
                    return subtotal * rate

                def total(price, quantity):
                    subtotal = price * quantity
                    amount = tax(subtotal)
                    result = subtotal + amount
                    return result
                """
            ),
            encoding="utf-8",
        )
        (self.root / "main.py").write_text(
            textwrap.dedent(
                """
                from helper import total

                if __name__ == "__main__":
                    value = total(100, 2)
                    print(f"value={value}")
                """
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_records_variable_history_with_correct_lines(self) -> None:
        code, stdout, stderr = run_tracer(self.root)
        self.assertEqual(code, 0, stderr)
        self.assertIn("value=220.0", stdout)

        events = read_events(self.root)
        kinds = {event["kind"] for event in events}
        self.assertTrue({"session_start", "call", "line", "var", "return", "session_end"} <= kinds)

        vars_total = [
            event
            for event in events
            if event["kind"] == "var" and event["func"] == "total" and event["name"] == "result"
        ]
        self.assertTrue(vars_total)
        self.assertEqual(vars_total[-1]["value"], "220.0")
        module_value = [
            event
            for event in events
            if event["kind"] == "var" and event["func"] == "<module>" and event["name"] == "value"
        ]
        self.assertEqual(module_value[-1]["value"], "220.0")
        self.assertEqual(module_value[-1]["line"], 5)

        subtotal_history = [
            event
            for event in events
            if event["kind"] == "var" and event["name"] == "subtotal" and event["func"] == "total"
        ]
        self.assertEqual(subtotal_history[-1]["value"], "200")
        self.assertEqual(subtotal_history[-1]["line"], 7)

        returned = [event for event in events if event["kind"] == "return" and event["func"] == "total"]
        self.assertEqual(returned[-1]["value"], "220.0")

        end = events[-1]
        self.assertEqual(end["kind"], "session_end")
        self.assertEqual(end["status"], "ok")
        self.assertEqual(end["exit_code"], 0)

    def test_arguments_are_captured_at_call_time(self) -> None:
        run_tracer(self.root)
        events = read_events(self.root)
        arguments = [
            event
            for event in events
            if event["kind"] == "var" and event["func"] == "total" and event["name"] in ("price", "quantity")
        ]
        self.assertTrue(any(event["name"] == "price" and event["value"] == "100" for event in arguments))
        self.assertTrue(any(event["name"] == "quantity" and event["value"] == "2" for event in arguments))

    def test_traces_the_main_script_arguments(self) -> None:
        (self.root / "main.py").write_text(
            "import sys\nvalue = sys.argv[1]\nprint(value)\n",
            encoding="utf-8",
        )
        code, stdout, _ = run_tracer(self.root, ["hello"])
        self.assertEqual(code, 0)
        self.assertIn("hello", stdout)

    def test_deleted_locals_emit_tombstones(self) -> None:
        (self.root / "main.py").write_text(
            textwrap.dedent(
                """
                def work():
                    kept = 1
                    gone = 2
                    del gone
                    return kept

                work()
                """
            ),
            encoding="utf-8",
        )
        code, _, stderr = run_tracer(self.root)
        self.assertEqual(code, 0, stderr)
        events = read_events(self.root)
        tombstones = [
            event for event in events if event["kind"] == "del" and event["name"] == "gone"
        ]
        self.assertTrue(tombstones)
        self.assertEqual(tombstones[-1]["func"], "work")
        last_delete = events.index(tombstones[-1])
        self.assertFalse(
            any(
                event["kind"] == "var" and event.get("name") == "gone"
                for event in events[last_delete + 1 :]
            )
        )

    def test_reports_program_errors(self) -> None:
        (self.root / "main.py").write_text(
            "def explode():\n    value = 1\n    return value / 0\n\nexplode()\n",
            encoding="utf-8",
        )
        code, _, stderr = run_tracer(self.root)
        self.assertEqual(code, 1)
        self.assertIn("ZeroDivisionError", stderr)
        events = read_events(self.root)
        self.assertTrue(any(event["kind"] == "exception" for event in events))
        end = events[-1]
        self.assertEqual(end["status"], "error")
        self.assertEqual(end["exit_code"], 1)
        self.assertIn("ZeroDivisionError", end["error"])

    def test_non_integer_system_exit_is_an_error(self) -> None:
        (self.root / "main.py").write_text(
            "raise SystemExit('bad config')\n",
            encoding="utf-8",
        )
        code, _, stderr = run_tracer(self.root)
        self.assertEqual(code, 1)
        self.assertIn("bad config", stderr)
        end = read_events(self.root)[-1]
        self.assertEqual(end["status"], "error")
        self.assertEqual(end["exit_code"], 1)
        self.assertEqual(end["error"], "bad config")

    def test_does_not_trace_standard_library_frames(self) -> None:
        run_tracer(self.root)
        events = read_events(self.root)
        for event in events:
            file = event.get("file") or ""
            self.assertNotIn("site-packages", file)
            self.assertNotIn("importlib", file)

    def test_respects_event_limit(self) -> None:
        (self.root / "main.py").write_text(
            "total = 0\nfor index in range(3000):\n    total += index\nprint(total)\n",
            encoding="utf-8",
        )
        command = [
            sys.executable,
            str(TRACER_PATH),
            "run",
            "--trace-file",
            str(self.root / "trace.ndjson"),
            "--root",
            str(self.root),
            "--events-limit",
            "1000",
            "--",
            str(self.root / "main.py"),
        ]
        completed = subprocess.run(command, cwd=str(self.root), capture_output=True, text=True, timeout=30)
        self.assertEqual(completed.returncode, 0)
        events = read_events(self.root)
        self.assertLessEqual(len(events), 1100)
        kinds = [event["kind"] for event in events]
        self.assertIn("truncated", kinds)
        self.assertEqual(events[-1]["kind"], "session_end")
        self.assertTrue(events[-1]["truncated"])


class AnalyzeTests(unittest.TestCase):
    def test_extracts_assignments_and_dependencies(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "pricing.py"
            source.write_text(
                textwrap.dedent(
                    """
                    from catalog import TAX

                    def compute(price, quantity):
                        subtotal = price * quantity
                        amount = subtotal * TAX
                        total = subtotal + amount
                        for index in range(quantity):
                            total += index
                        return total

                    class Cart:
                        def __init__(self):
                            self.items = []
                    """
                ),
                encoding="utf-8",
            )
            completed = subprocess.run(
                [sys.executable, str(TRACER_PATH), "analyze", str(source)],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            payload = json.loads(completed.stdout)
            file_entry = payload["files"][0]
            self.assertEqual(file_entry["errors"], [])
            assignments = {(item["line"], item["target"]): item for item in file_entry["assignments"]}

            subtotal = assignments[(5, "subtotal")]
            self.assertEqual(subtotal["func"], "compute")
            self.assertIn("price", subtotal["sources"])
            self.assertIn("quantity", subtotal["sources"])

            total = assignments[(7, "total")]
            self.assertEqual(set(total["sources"]), {"subtotal", "amount"})

            augmented = assignments[(9, "total")]
            self.assertEqual(augmented["kind"], "augassign")
            self.assertIn("total", augmented["sources"])

            self.assertIn((14, "self.items"), assignments)

    def test_survives_syntax_errors(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "broken.py"
            source.write_text("def broken(:\n", encoding="utf-8")
            completed = subprocess.run(
                [sys.executable, str(TRACER_PATH), "analyze", str(source)],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(completed.returncode, 0)
            payload = json.loads(completed.stdout)
            self.assertTrue(payload["files"][0]["errors"])


if __name__ == "__main__":
    unittest.main()
