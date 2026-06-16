#!/usr/bin/env bash
#
# build_dmg.sh — build a Release .app of Swift Deep Research and package it into a
# distributable .dmg (drag-to-/Applications layout).
#
# The project signs ad-hoc (CODE_SIGN_IDENTITY = "-") with the hardened runtime
# on. There is no Developer ID identity on this machine, so the result is NOT
# notarized — first launch needs a one-time Gatekeeper override (right-click →
# Open, or `xattr -dr com.apple.quarantine "/Applications/Swift Deep Research.app"`).
# That caveat is printed at the end and documented in the GitHub release notes.
#
# Usage:  bash scripts/build_dmg.sh [version]
#   version  optional marketing version label for the dmg name (default: read
#            MARKETING_VERSION from the build settings).
#
# Output:  release/Swift-Deep-Research-<version>.dmg  (gitignored)
#
# Safe to re-run; it cleans its own intermediate staging each time.
set -euo pipefail
export LC_ALL=${LC_ALL:-en_US.UTF-8} LANG=${LANG:-en_US.UTF-8}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="Swift Deep Research.xcodeproj"
SCHEME="Swift Deep Research"
APP_NAME="Swift Deep Research"
CONFIG="Release"
OUT_DIR="$ROOT_DIR/release"
DERIVED="$ROOT_DIR/release/DerivedData"
STAGE="$ROOT_DIR/release/dmg-stage"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }

bold "==> Building $CONFIG ($SCHEME)..."
rm -rf "$STAGE"
mkdir -p "$OUT_DIR" "$STAGE"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  clean build

APP_PATH="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: built app not found at $APP_PATH" >&2
  exit 1
fi

# Resolve version (argument wins; else read from the built Info.plist).
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo '1.0')"
fi
DMG_NAME="Swift-Deep-Research-${VERSION}.dmg"
DMG_PATH="$OUT_DIR/$DMG_NAME"

bold "==> Staging app + /Applications symlink..."
cp -R "$APP_PATH" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

# Ad-hoc (re)sign the staged copy deeply so the bundle is internally consistent
# after the copy (xcodebuild already ad-hoc signs, but re-sign to be safe).
codesign --force --deep --sign - "$STAGE/$APP_NAME.app" 2>/dev/null || true

bold "==> Creating ${DMG_NAME} ..."
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH"

rm -rf "$STAGE"

SIZE="$(du -h "$DMG_PATH" | cut -f1)"
bold "==> Done: $DMG_PATH ($SIZE)"
echo
echo "NOTE: this build is ad-hoc signed and NOT notarized. On first launch users"
echo "should right-click the app → Open (or run:"
echo "  xattr -dr com.apple.quarantine \"/Applications/$APP_NAME.app\")."
