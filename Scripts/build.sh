#!/usr/bin/env bash
#
# Build the Fillline menu-bar app bundle in Debug configuration.
#
# Requires: Xcode (not just Command Line Tools) and XcodeGen.
# The UsageCore library alone builds without Xcode: `swift build && swift test`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="Fillline"
CONFIGURATION="Debug"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found." >&2
  echo "       Install it with: brew install xcodegen" >&2
  exit 1
fi

# Xcode can be installed but not *selected* (`xcode-select -p` still points at the CLT).
# DEVELOPER_DIR selects it for this process only, so no root password is required.
if ! xcodebuild -version >/dev/null 2>&1 && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# `xcodebuild` exists as a stub with Command Line Tools alone, but fails until a full
# Xcode is selected, so test it by actually running it.
if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: Xcode is required (only Command Line Tools found)." >&2
  echo "       Install Xcode from the App Store, then run:" >&2
  echo "         sudo xcode-select -s /Applications/Xcode.app" >&2
  echo "       The core library still builds without Xcode: swift build && swift test" >&2
  exit 1
fi

echo "==> Generating $APP_NAME.xcodeproj from project.yml"
xcodegen generate

echo "==> Building $APP_NAME ($CONFIGURATION)"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath build \
  build

APP_PATH="$REPO_ROOT/build/Build/Products/$CONFIGURATION/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "error: build succeeded but $APP_PATH is missing." >&2
  exit 1
fi

echo
echo "Built: $APP_PATH"
echo "Run it with: open \"$APP_PATH\""
