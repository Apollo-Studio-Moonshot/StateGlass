#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${STATEGLASS_APP_OUTPUT:-$ROOT/build/Stateglass.app}"
CONTENTS="$APP/Contents"

cargo build --manifest-path "$ROOT/src-tauri/Cargo.toml" --release --bin stateglass-sidecar
swift build --package-path "$ROOT/xcode" -c release

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/python"
cp "$ROOT/xcode/.build/release/StateGlass" "$CONTENTS/MacOS/StateGlass"
cp "$ROOT/src-tauri/target/release/stateglass-sidecar" "$CONTENTS/Resources/stateglass-sidecar"
cp "$ROOT/python/stateglass_tracer.py" "$CONTENTS/Resources/python/stateglass_tracer.py"
cp "$ROOT/src-tauri/icons/icon.icns" "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>StateGlass</string>
    <key>CFBundleIdentifier</key>
    <string>dev.stateglass.app</string>
    <key>CFBundleName</key>
    <string>Stateglass</string>
    <key>CFBundleDisplayName</key>
    <string>Stateglass</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Built $APP"
if [[ "${1:-}" == "--open" ]]; then
    open "$APP"
fi
