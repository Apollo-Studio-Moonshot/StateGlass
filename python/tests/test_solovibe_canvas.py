import tempfile
import unittest
from pathlib import Path
import sys
import json
import os
import subprocess

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from solovibe.canvas import CanvasStore


class CanvasStoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.store = CanvasStore(Path(self.directory.name) / "canvas.sqlite3")

    def tearDown(self):
        self.store.close()
        self.directory.cleanup()

    def test_seeds_context_nodes_and_dependencies_once(self):
        canvas = self.store.list_canvas()
        self.assertEqual(len(canvas["nodes"]), 4)
        self.assertEqual(len(canvas["dependencies"]), 2)
        self.store._seed_if_empty()
        self.assertEqual(len(self.store.list_canvas()["nodes"]), 4)

    def test_database_changes_mark_dependent_nodes_for_review(self):
        canvas = self.store.list_canvas()
        database = next(node for node in canvas["nodes"] if node["kind"] == "database")
        frontend = next(node for node in canvas["nodes"] if node["kind"] == "frontend")

        updated = self.store.update_node(
            {"id": database["id"], "title": "Updated product schema"}
        )
        refreshed = self.store.list_canvas()
        affected = next(node for node in refreshed["nodes"] if node["id"] == frontend["id"])

        self.assertEqual(updated["title"], "Updated product schema")
        self.assertEqual(affected["status"], "needsReview")

    def test_rejects_duplicate_and_self_dependencies(self):
        canvas = self.store.list_canvas()
        database = next(node for node in canvas["nodes"] if node["kind"] == "database")
        frontend = next(node for node in canvas["nodes"] if node["kind"] == "frontend")

        with self.assertRaisesRegex(ValueError, "already exists"):
            self.store.add_dependency(
                {"sourceId": database["id"], "targetId": frontend["id"]}
            )
        with self.assertRaisesRegex(ValueError, "cannot depend on itself"):
            self.store.add_dependency(
                {"sourceId": database["id"], "targetId": database["id"]}
            )

    def test_jsonl_protocol_returns_canvas_and_validation_errors(self):
        data_dir = Path(self.directory.name) / "app-data"
        environment = os.environ.copy()
        environment["SOLOVIBE_DATA_DIR"] = str(data_dir)
        environment["PYTHONPATH"] = str(Path(__file__).resolve().parents[1])
        requests = [
            {"id": "canvas", "method": "list_canvas", "protocolVersion": 1, "params": {}},
            {"id": "bad", "method": "not_a_method", "protocolVersion": 1, "params": {}},
        ]
        process = subprocess.run(
            [sys.executable, "-m", "solovibe"],
            input="".join(json.dumps(request) + "\n" for request in requests),
            capture_output=True,
            text=True,
            env=environment,
            check=True,
        )
        responses = [json.loads(line) for line in process.stdout.splitlines()]

        self.assertEqual(responses[0]["id"], "canvas")
        self.assertEqual(len(responses[0]["result"]["nodes"]), 4)
        self.assertEqual(responses[1]["id"], "bad")
        self.assertIn("Unknown backend method", responses[1]["error"]["message"])


if __name__ == "__main__":
    unittest.main()
