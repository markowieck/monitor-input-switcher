#!/bin/bash
# Builds MonitorInputSwitcher.app from the Swift package and ad-hoc signs it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_NAME="MonitorInputSwitcher"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"

echo "==> Building release binary..."
cd "$ROOT_DIR"
swift build -c release

echo "==> Assembling $APP_NAME.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "==> Ad-hoc signing..."
codesign --force --deep --sign - "$APP_DIR"

echo "==> Done: $APP_DIR"
echo "    Move it to /Applications and open it, or run: open \"$APP_DIR\""
