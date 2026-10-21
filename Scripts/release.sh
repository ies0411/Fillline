#!/usr/bin/env bash
#
# Release pipeline:
#   universal build -> Developer ID sign -> notarize -> staple -> DMG -> notarize DMG -> staple
#
# Required environment (no defaults, no prompts — fail fast if unset):
#   DEVELOPER_ID    "Developer ID Application: Your Name (TEAMID)"
#   TEAM_ID         10-character Apple Developer Team ID
#   NOTARY_PROFILE  notarytool keychain profile, created once with:
#                     xcrun notarytool store-credentials "<profile>" \
#                       --apple-id "<you@example.com>" \
#                       --team-id "<TEAM_ID>" \
#                       --password "<app-specific-password>"
#
# Optional:
#   VERSION         defaults to MARKETING_VERSION in project.yml
#   NOTARY_TIMEOUT  notarytool --wait timeout, e.g. 30m (default: notarytool's own)
#
# Signing identity placeholders live in release/ExportOptions.plist (teamID, method
# `developer-id`, signingCertificate `Developer ID Application`). That file is a template
# only: this script signs the .app directly and never writes a Team ID into the repo.
# Set EXPORT_OPTIONS and use `xcodebuild -exportArchive` instead if you prefer that path.
#
# Never hardcode a Team ID, certificate name, Apple ID, or app-specific password here.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="Fillline"
DIST="$REPO_ROOT/dist"
APP="$REPO_ROOT/build/Build/Products/Release/$APP_NAME.app"

: "${DEVELOPER_ID:?set DEVELOPER_ID to your 'Developer ID Application: ...' identity}"
: "${TEAM_ID:?set TEAM_ID to your Apple Developer Team ID}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile (xcrun notarytool store-credentials)}"

VERSION="${VERSION:-$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*//p' project.yml | head -n 1 | tr -d '"')}"
: "${VERSION:?could not determine VERSION; set it explicitly}"

DMG="$DIST/${APP_NAME}-${VERSION}.dmg"
ZIP="$DIST/${APP_NAME}-${VERSION}.zip"

# Keep the identity and the team in sync; a mismatch produces a build that notarizes but
# fails Gatekeeper on other machines.
case "$DEVELOPER_ID" in
  *"($TEAM_ID)") ;;
  *)
    echo "error: DEVELOPER_ID does not end with ($TEAM_ID)." >&2
    echo "       Got: $DEVELOPER_ID" >&2
    exit 1
    ;;
esac

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: Xcode is required (only Command Line Tools found)." >&2
  exit 1
fi

echo "==> Release $APP_NAME $VERSION (team $TEAM_ID)"
echo "==> Generating project"
xcodegen generate

echo "==> Building universal Release binary"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  build

if [ ! -d "$APP" ]; then
  echo "error: expected app bundle at $APP" >&2
  exit 1
fi

echo "==> Architectures: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"

echo "==> Signing with Developer ID (hardened runtime, timestamp)"
codesign \
  --deep \
  --force \
  --options runtime \
  --timestamp \
  --sign "$DEVELOPER_ID" \
  "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p "$DIST"

echo "==> Notarizing app bundle"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
rm -f "$ZIP"

echo "==> Stapling app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Creating DMG"
rm -f "$DMG"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$APP" \
  -ov \
  -format UDZO \
  "$DMG"

echo "==> Signing DMG"
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"

echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Verifying Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP"

echo
echo "Release artifacts:"
echo "  $DMG"
echo "  $APP"
echo
echo "Next: create a GitHub release tagged v$VERSION and attach the DMG."
