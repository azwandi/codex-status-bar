#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodexStatusBar"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
APP_VERSION="${APP_VERSION:-0.2.5}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
BUILD_DIR="$ROOT_DIR/.build"

cd "$ROOT_DIR"

xcrun swift build -c "$BUILD_CONFIG"

TRIPLE_DIR="$(find "$BUILD_DIR" -maxdepth 1 -type d -name '*-apple-macosx' | head -n 1)"
if [[ -z "${TRIPLE_DIR:-}" ]]; then
  echo "Could not find Swift build output directory." >&2
  exit 1
fi

PRODUCT_DIR="$TRIPLE_DIR/$BUILD_CONFIG"
EXECUTABLE_PATH="$PRODUCT_DIR/$APP_NAME"
if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Executable not found at $EXECUTABLE_PATH" >&2
  exit 1
fi

APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

cp "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>CodexStatusBar</string>
  <key>CFBundleIdentifier</key>
  <string>com.azwandi.codex-status-bar</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>CodexStatusBar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

if [[ -d "$PRODUCT_DIR/SwiftTerm_SwiftTerm.bundle" ]]; then
  cp -R "$PRODUCT_DIR/SwiftTerm_SwiftTerm.bundle" "$RESOURCES_DIR/"
fi

xcrun swift-stdlib-tool \
  --copy \
  --platform macosx \
  --scan-executable "$MACOS_DIR/$APP_NAME" \
  --destination "$FRAMEWORKS_DIR"

codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
