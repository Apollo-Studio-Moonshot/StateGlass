#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIDECAR="$ROOT/backend/target/debug/stateglass-sidecar"

cargo build --manifest-path "$ROOT/backend/Cargo.toml" --bin stateglass-sidecar
cd "$ROOT/xcode"
STATEGLASS_SIDECAR_PATH="$SIDECAR" swift run StateGlass
