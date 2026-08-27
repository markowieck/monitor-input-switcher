#!/bin/bash
# Builds MonitorInputSwitcher.app from the Swift package and ad-hoc signs it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MonitorInputSwitcher"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"

echo "==> Building universal (arm64 + x86_64) release binary..."
cd "$ROOT_DIR"
if swift build -c release --arch arm64 --arch x86_64; then
    BUILT_BINARY="$ROOT_DIR/.build/apple/Products/Release/$APP_NAME"
else
    echo "==> Universal build failed, falling back to host-architecture-only build..."
    swift build -c release
    BUILT_BINARY="$ROOT_DIR/.build/release/$APP_NAME"
fi

echo "==> Assembling $APP_NAME.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILT_BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "==> Ad-hoc signing..."
codesign --force --deep --sign - "$APP_DIR"

echo "==> Done: $APP_DIR"
echo "    Move it to /Applications and open it, or run: open \"$APP_DIR\""
