#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${STATEGLASS_APP_OUTPUT:-$ROOT/build/Stateglass.app}"
CONTENTS="$APP/Contents"
SUPPORT="$ROOT/xcode/Support"
IDENTITY="${STATEGLASS_CODESIGN_IDENTITY:--}"

# Build a universal (arm64 + x86_64) binary with STATEGLASS_UNIVERSAL=1.
mkdir -p "$ROOT/xcode/.build/release"
if [[ "${STATEGLASS_UNIVERSAL:-0}" == "1" ]]; then
    swift build --package-path "$ROOT/xcode" -c release --arch arm64
    swift build --package-path "$ROOT/xcode" -c release --arch x86_64
    lipo -create \
        "$ROOT/xcode/.build/arm64-apple-macosx/release/StateGlass" \
        "$ROOT/xcode/.build/x86_64-apple-macosx/release/StateGlass" \
        -output "$ROOT/xcode/.build/release/StateGlass"

    cargo build --manifest-path "$ROOT/src-tauri/Cargo.toml" --release --bin stateglass-sidecar --target aarch64-apple-darwin
    cargo build --manifest-path "$ROOT/src-tauri/Cargo.toml" --release --bin stateglass-sidecar --target x86_64-apple-darwin
    lipo -create \
        "$ROOT/src-tauri/target/aarch64-apple-darwin/release/stateglass-sidecar" \
        "$ROOT/src-tauri/target/x86_64-apple-darwin/release/stateglass-sidecar" \
        -output "$ROOT/src-tauri/target/release/stateglass-sidecar"
else
    cargo build --manifest-path "$ROOT/src-tauri/Cargo.toml" --release --bin stateglass-sidecar
    swift build --package-path "$ROOT/xcode" -c release
fi

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/python"
cp "$ROOT/xcode/.build/release/StateGlass" "$CONTENTS/MacOS/StateGlass"
cp "$ROOT/src-tauri/target/release/stateglass-sidecar" "$CONTENTS/Resources/stateglass-sidecar"
cp "$ROOT/python/stateglass_tracer.py" "$CONTENTS/Resources/python/stateglass_tracer.py"
cp -R "$ROOT/python/solovibe" "$CONTENTS/Resources/python/solovibe"
cp "$ROOT/src-tauri/icons/icon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$SUPPORT/Stateglass.sdef" "$CONTENTS/Resources/Stateglass.sdef"

# SwiftPM resource bundle declared in Package.swift (the SVG icon set).
# Copy it into Contents/Resources so `Bundle.module` resolves it at runtime.
RESOURCE_BUNDLE=""
for candidate in \
    "$ROOT"/xcode/.build/release \
    "$ROOT"/xcode/.build/out/Products/Release \
    "$ROOT"/xcode/.build/*-apple-macosx/release; do
    if [[ -d "$candidate/StateGlass_StateGlass.bundle" ]]; then
        RESOURCE_BUNDLE="$candidate/StateGlass_StateGlass.bundle"
        break
    fi
done
if [[ -z "$RESOURCE_BUNDLE" ]]; then
    RESOURCE_BUNDLE="$(find "$ROOT/xcode/.build" -type d -name StateGlass_StateGlass.bundle -print -quit 2>/dev/null || true)"
fi
if [[ -n "$RESOURCE_BUNDLE" ]]; then
    ditto "$RESOURCE_BUNDLE" "$CONTENTS/Resources/StateGlass_StateGlass.bundle"
fi

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
    <string>26.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Stateglass.</string>

    <!-- Handoff / Continuity -->
    <key>NSUserActivityTypes</key>
    <array>
        <string>dev.stateglass.project</string>
    </array>

    <!-- Services menu: "Open Project in Stateglass" -->
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>Open Project in Stateglass</string>
            </dict>
            <key>NSMessage</key>
            <string>openProject</string>
            <key>NSPortName</key>
            <string>Stateglass</string>
            <key>NSSendTypes</key>
            <array>
                <string>NSFilenamesPboardType</string>
            </array>
        </dict>
    </array>

    <!-- AppleScript / JXA -->
    <key>NSAppleScriptEnabled</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Stateglass can be controlled by AppleScript and Shortcuts.</string>
    <key>OSAScriptingDefinition</key>
    <string>Stateglass.sdef</string>
</dict>
</plist>
PLIST

# Sign the nested sidecar first, then the app bundle. Ad-hoc signing is the
# default; set STATEGLASS_CODESIGN_IDENTITY to a Developer ID for distribution.
codesign --force --options runtime --sign "$IDENTITY" "$CONTENTS/Resources/stateglass-sidecar"
codesign --force --options runtime \
    --entitlements "$SUPPORT/StateGlass.entitlements" \
    --sign "$IDENTITY" "$APP"

if [[ -n "${STATEGLASS_NOTARY_PROFILE:-}" && "$IDENTITY" != "-" ]]; then
    ZIP="$APP.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$STATEGLASS_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
fi

echo "Built $APP"
if [[ "${1:-}" == "--open" ]]; then
    open "$APP"
fi
