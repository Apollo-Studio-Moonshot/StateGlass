from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

from .canvas import CanvasStore

PROTOCOL_VERSION = 1


def _data_path() -> Path:
    configured = os.environ.get("SOLOVIBE_DATA_DIR")
    if configured:
        directory = Path(configured)
    else:
        directory = Path.home() / "Library" / "Application Support" / "dev.solovibe.app"
    directory.mkdir(parents=True, exist_ok=True)
    return directory / "solovibe.sqlite3"


def dispatch(method: str, params: dict[str, Any], store: CanvasStore) -> Any:
    if method == "list_canvas":
        return store.list_canvas()
    if method == "add_node":
        return store.add_node(params)
    if method == "update_node":
        return store.update_node(params)
    if method == "add_dependency":
        return store.add_dependency(params)
    if method == "remove_dependency":
        return store.remove_dependency(params)
    raise ValueError(f"Unknown backend method: {method}")


def main() -> None:
    store = CanvasStore(_data_path())
    for line in sys.stdin:
        request: Any = {}
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("Request must be a JSON object")
            if request.get("protocolVersion") != PROTOCOL_VERSION:
                raise ValueError("Unsupported protocol version")
            params = request.get("params", {})
            if not isinstance(params, dict):
                raise ValueError("Request params must be an object")
            result = dispatch(request["method"], params, store)
            response = {
                "kind": "response",
                "protocolVersion": PROTOCOL_VERSION,
                "id": request["id"],
                "result": result,
            }
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            response = {
                "kind": "response",
                "protocolVersion": PROTOCOL_VERSION,
                "id": request.get("id") if isinstance(request, dict) else None,
                "error": {"kind": "validation", "message": str(error)},
            }
        print(json.dumps(response, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
