#!/bin/bash
# Builds SilentWhisper.app. Run ./build.sh, then open SilentWhisper.app.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${1:-release}
APP="SilentWhisper.app"
VERSION=$(cat VERSION)

[ -f AppIcon.icns ] || ./makeicon.sh

swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SilentWhisper" "$APP/Contents/MacOS/"
cp AppIcon.icns "$APP/Contents/Resources/"

# WhisperKit ships Metal/CoreML resource bundles next to the binary — they must come along.
cp -R "$BIN"/*.bundle "$APP/Contents/Resources/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Silent Whisper</string>
  <key>CFBundleDisplayName</key>       <string>Silent Whisper</string>
  <key>CFBundleExecutable</key>        <string>SilentWhisper</string>
  <key>CFBundleIdentifier</key>        <string>com.nuh.silentwhisper</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Silent Whisper transcribes your speech on-device.</string>
  <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# A stable signing identity is what makes Accessibility permission survive a rebuild.
# Ad-hoc works, but its hash changes every time, so macOS quietly revokes the grant.
# Developer ID first: it is the identity that lets other people run the app, and it is
# stable across machines. Apple Development works for local use only.
# `|| true`: with pipefail a no-match grep would otherwise abort the whole script.
CERTS=$(security find-identity -v -p codesigning 2>/dev/null || true)
IDENTITY=$(echo "$CERTS" | grep -oE '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)
[ -n "$IDENTITY" ] || IDENTITY=$(echo "$CERTS" | grep -oE '"Apple Development[^"]*"' | head -1 | tr -d '"' || true)

if [ -n "$IDENTITY" ]; then
  # --options runtime is what notarization requires; the entitlements give the mic and
  # CoreML compilation back afterwards.
  codesign --force --deep --options runtime \
    --entitlements SilentWhisper.entitlements \
    --sign "$IDENTITY" "$APP"
  echo "signed with: $IDENTITY"
else
  codesign --force --deep --sign - "$APP"
  echo "signed ad-hoc — macOS will drop Accessibility on every rebuild."
  echo "  after each build: remove the old Silent Whisper row in System Settings >"
  echo "  Privacy & Security > Accessibility, then re-add this app."
fi

echo "built $APP — grant Microphone and Accessibility, then hold right ⌥ to talk."
