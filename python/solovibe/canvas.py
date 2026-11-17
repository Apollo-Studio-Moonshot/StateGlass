from __future__ import annotations

import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any

NODE_KINDS = {"frontend", "billing", "marketing", "database"}
NODE_STATUSES = {"draft", "active", "needsReview"}

SEED_NODES = (
    ("database", "Product schema", "Users, plans, and subscription state.", 120.0, 100.0),
    ("frontend", "Pricing page", "Show plans and make the next step obvious.", 440.0, 100.0),
    ("billing", "Stripe billing", "Checkout, subscription lifecycle, and webhooks.", 120.0, 350.0),
    ("marketing", "Launch copy", "SEO metadata and the first announcement post.", 440.0, 350.0),
)


class CanvasStore:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(path)
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA foreign_keys = ON")
        self.connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS context_nodes (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                summary TEXT NOT NULL,
                status TEXT NOT NULL,
                x REAL NOT NULL,
                y REAL NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS node_dependencies (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES context_nodes(id) ON DELETE CASCADE,
                target_id TEXT NOT NULL REFERENCES context_nodes(id) ON DELETE CASCADE,
                UNIQUE(source_id, target_id),
                CHECK(source_id <> target_id)
            );
            """
        )
        self._seed_if_empty()

    def close(self) -> None:
        self.connection.close()

    def _seed_if_empty(self) -> None:
        count = self.connection.execute("SELECT COUNT(*) FROM context_nodes").fetchone()[0]
        if count:
            return
        with self.connection:
            node_ids: dict[str, str] = {}
            for kind, title, summary, x, y in SEED_NODES:
                node_id = str(uuid.uuid4())
                node_ids[kind] = node_id
                self.connection.execute(
                    """
                    INSERT INTO context_nodes (id, kind, title, summary, status, x, y, updated_at)
                    VALUES (?, ?, ?, ?, 'draft', ?, ?, ?)
                    """,
                    (node_id, kind, title, summary, x, y, _now_ms()),
                )
            self.connection.executemany(
                "INSERT INTO node_dependencies (id, source_id, target_id) VALUES (?, ?, ?)",
                [
                    (str(uuid.uuid4()), node_ids["database"], node_ids["frontend"]),
                    (str(uuid.uuid4()), node_ids["billing"], node_ids["frontend"]),
                ],
            )

    def list_canvas(self) -> dict[str, list[dict[str, Any]]]:
        nodes = self.connection.execute(
            """
            SELECT id, kind, title, summary, status, x, y
            FROM context_nodes ORDER BY updated_at, title
            """
        ).fetchall()
        dependencies = self.connection.execute(
            """
            SELECT id, source_id AS sourceId, target_id AS targetId
            FROM node_dependencies ORDER BY rowid
            """
        ).fetchall()
        return {
            "nodes": [dict(row) for row in nodes],
            "dependencies": [dict(row) for row in dependencies],
        }

    def add_node(self, params: dict[str, Any]) -> dict[str, Any]:
        kind = params.get("kind")
        if kind not in NODE_KINDS:
            raise ValueError("Unsupported context node type")
        title = _text(params.get("title"), "title", 120)
        node_id = str(uuid.uuid4())
        x, y = params.get("x", 120.0), params.get("y", 100.0)
        if not isinstance(x, (int, float)) or not isinstance(y, (int, float)):
            raise ValueError("Node position must be numeric")
        with self.connection:
            self.connection.execute(
                """
                INSERT INTO context_nodes (id, kind, title, summary, status, x, y, updated_at)
                VALUES (?, ?, ?, '', 'draft', ?, ?, ?)
                """,
                (node_id, kind, title, float(x), float(y), _now_ms()),
            )
        return next(node for node in self.list_canvas()["nodes"] if node["id"] == node_id)

    def update_node(self, params: dict[str, Any]) -> dict[str, Any]:
        node_id = params.get("id")
        row = self.connection.execute(
            "SELECT id, kind, title, summary, status, x, y FROM context_nodes WHERE id = ?",
            (node_id,),
        ).fetchone()
        if row is None:
            raise ValueError("Context node was not found")
        title = _text(params.get("title", row["title"]), "title", 120)
        summary = _text(params.get("summary", row["summary"]), "summary", 1000, allow_empty=True)
        status = params.get("status", row["status"])
        if status not in NODE_STATUSES:
            raise ValueError("Unsupported context node status")
        x, y = params.get("x", row["x"]), params.get("y", row["y"])
        if not isinstance(x, (int, float)) or not isinstance(y, (int, float)):
            raise ValueError("Node position must be numeric")
        with self.connection:
            self.connection.execute(
                """
                UPDATE context_nodes SET title = ?, summary = ?, status = ?, x = ?, y = ?, updated_at = ?
                WHERE id = ?
                """,
                (title, summary, status, float(x), float(y), _now_ms(), node_id),
            )
            if row["kind"] == "database" and (
                title != row["title"] or summary != row["summary"]
            ):
                self.connection.execute(
                    """
                    UPDATE context_nodes SET status = 'needsReview', updated_at = ?
                    WHERE id IN (
                        SELECT target_id FROM node_dependencies WHERE source_id = ?
                    ) AND status <> 'needsReview'
                    """,
                    (_now_ms(), node_id),
                )
        return next(node for node in self.list_canvas()["nodes"] if node["id"] == node_id)

    def add_dependency(self, params: dict[str, Any]) -> dict[str, Any]:
        source_id = params.get("sourceId")
        target_id = params.get("targetId")
        if source_id == target_id:
            raise ValueError("A node cannot depend on itself")
        dependency_id = str(uuid.uuid4())
        try:
            with self.connection:
                self.connection.execute(
                    """
                    INSERT INTO node_dependencies (id, source_id, target_id)
                    VALUES (?, ?, ?)
                    """,
                    (dependency_id, source_id, target_id),
                )
        except sqlite3.IntegrityError as error:
            raise ValueError("Dependency is invalid or already exists") from error
        return next(
            edge for edge in self.list_canvas()["dependencies"] if edge["id"] == dependency_id
        )

    def remove_dependency(self, params: dict[str, Any]) -> bool:
        with self.connection:
            cursor = self.connection.execute(
                "DELETE FROM node_dependencies WHERE id = ?", (params.get("id"),)
            )
        if cursor.rowcount == 0:
            raise ValueError("Dependency was not found")
        return True


def _text(value: Any, label: str, limit: int, allow_empty: bool = False) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{label.capitalize()} must be text")
    normalized = value.strip()
    if (not normalized and not allow_empty) or len(normalized) > limit:
        raise ValueError(f"{label.capitalize()} must be between 1 and {limit} characters")
    return normalized


def _now_ms() -> int:
    return time.time_ns() // 1_000_000
