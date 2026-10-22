#!/usr/bin/env bash
#
# screenshots.sh — render the documentation popover screenshots (issue #6).
#
# Screen capture is not available on the reference machine (TCC denies `screencapture`), so the
# app itself draws its real SwiftUI views offscreen with `ImageRenderer` when
# FILLLINE_RENDER_SHOTS names an output directory, then exits. Nothing here is a mockup.
#
# Output: docs/marketing/assets/app-popover-{healthy,degraded}-{light,dark}.png
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Xcode can be installed but not *selected* (`xcode-select -p` still points at the CLT).
# DEVELOPER_DIR selects it for this process only, so no root password is required.
if ! xcodebuild -version >/dev/null 2>&1 && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

OUT="$ROOT/docs/marketing/assets"
mkdir -p "$OUT"

echo "==> Building the app bundle"
./Scripts/build.sh

BIN="$ROOT/build/Build/Products/Debug/Fillline.app/Contents/MacOS/Fillline"
if [ ! -x "$BIN" ]; then
    echo "error: $BIN is missing or not executable." >&2
    exit 1
fi

echo "==> Rendering into $OUT"
# Drop earlier output first, so a stale file can never pass for a fresh render.
rm -f "$OUT"/app-popover-*.png
FILLLINE_RENDER_SHOTS="$OUT" "$BIN"

PNGS=("$OUT"/app-popover-*.png)
if [ ! -e "${PNGS[0]}" ]; then
    echo "error: no app-popover-*.png was produced." >&2
    exit 1
fi
if [ "${#PNGS[@]}" -lt 6 ]; then
    echo "error: expected 6 screenshots (healthy + degraded + crowded, light + dark), found ${#PNGS[@]}." >&2
    exit 1
fi

echo
for png in "${PNGS[@]}"; do
    echo "$png"
    sips -g pixelWidth -g pixelHeight "$png" | sed -n '2,3p'
done
