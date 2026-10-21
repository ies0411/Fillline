#!/usr/bin/env bash
#
# test-local.sh — execute the UsageCore suite on a Command-Line-Tools-only Mac.
#
# Why: with CLT only there is no `xctest` harness, so `swift test` builds the test
# bundle but never runs it (it can even exit 0 with no output), which makes
# "N tests passed" unverifiable. This script builds a throwaway runner outside the
# repo that links the UsageCore library plus the real Tests/UsageCoreTests/*.swift
# files and drives swift-testing's SwiftPM entry point. CI uses plain `swift test`
# on an Xcode runner, where the real harness exists.
#
# Usage: ./Scripts/test-local.sh [extra swift-testing args, e.g. --filter Parsing]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Xcode can be installed but not *selected* (`xcode-select -p` still points at the CLT).
# DEVELOPER_DIR selects it for this process only, so no root password is required.
if ! xcodebuild -version >/dev/null 2>&1 && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Prefer the real harness when full Xcode is installed. A merely resolvable xctest is
# not enough: xcrun can return a non-Mach-O stub and `swift test` would run nothing.
if xcodebuild -version >/dev/null 2>&1 \
    || { p="$(xcrun --find xctest 2>/dev/null)" && file -b "$p" | grep -q Mach-O; }; then
    exec swift test --parallel "$@"
fi
# CLT fallback: Testing.framework and its macro plugin are outside SwiftPM's default paths.
CLT="$(xcode-select -p)"
FRAMEWORKS="$CLT/Library/Developer/Frameworks"
[[ -d "$FRAMEWORKS/Testing.framework" ]] \
    || { echo "error: Testing.framework missing under $FRAMEWORKS" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/usagecore-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Entry point, plus the `Bundle.module` accessor SwiftPM normally synthesizes.
cat > "$TMP/main.swift" <<'SWIFT'
import Foundation
import Testing

extension Bundle {
    static var module: Bundle {
        guard let path = ProcessInfo.processInfo.environment["USAGECORE_FIXTURES"],
              let bundle = Bundle(path: path) else {
            fatalError("USAGECORE_FIXTURES is not set to the Fixtures directory")
        }
        return bundle
    }
}

exit(await Testing.__swiftPMEntryPoint())
SWIFT
swift build >/dev/null
OBJECTS=("$ROOT"/.build/debug/UsageCore.build/*.o)
[[ -e "${OBJECTS[0]}" ]] || { echo "error: no UsageCore objects after swift build" >&2; exit 1; }
# SwiftPM keeps library targets as loose objects, so archive them like a product.
libtool -static -o "$TMP/libUsageCore.a" "${OBJECTS[@]}"
swiftc -swift-version 6 -o "$TMP/runner" \
    -I "$ROOT/.build/debug/Modules" -L "$TMP" -lUsageCore \
    -F "$FRAMEWORKS" -plugin-path "$CLT/usr/lib/swift/host/plugins/testing" \
    -Xfrontend -disable-cross-import-overlay-search \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    "$TMP/main.swift" "$ROOT"/Tests/UsageCoreTests/*.swift
LOG="$TMP/output.log"
set +e
NO_COLOR=1 USAGECORE_FIXTURES="$ROOT/Tests/UsageCoreTests/Fixtures" \
    "$TMP/runner" "$@" 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e
# A failed or zero-test run must never look like success — the bug this fixes.
[[ $STATUS -eq 0 ]] || { echo "error: test run failed (exit $STATUS)" >&2; exit "$STATUS"; }
grep -qE "Test run with [1-9][0-9]* test" "$LOG" \
    || { echo "error: zero tests executed" >&2; exit 1; }
