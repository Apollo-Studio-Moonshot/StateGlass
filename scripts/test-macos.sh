#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$ROOT/backend" && cargo test)
(cd "$ROOT/xcode" && swift build)
(cd "$ROOT" && python3 -m unittest discover -s python/tests -v)
