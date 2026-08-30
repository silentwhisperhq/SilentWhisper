#!/bin/bash
# Packages SilentWhisper.app into a drag-to-Applications DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION)
DMG="SilentWhisper-$VERSION.dmg"
STAGE=$(mktemp -d)/SilentWhisper

mkdir -p "$STAGE"
ditto SilentWhisper.app "$STAGE/SilentWhisper.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Silent Whisper" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$(dirname "$STAGE")"

# The DMG is signed too, so Gatekeeper trusts the container as well as the app inside.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)
[ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$DMG"

echo "built $DMG"
