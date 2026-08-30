#!/bin/bash
# Builds SilentWhisper.app. Run ./build.sh, then open SilentWhisper.app.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${1:-release}
APP="SilentWhisper.app"
VERSION=$(cat VERSION)

# Builds handed straight to a machine get a "beta · by Claude" marker so they are
# distinguishable from a real download. release.sh sets SW_RELEASE to turn it off.
DEV_BUILD=$([ -n "${SW_RELEASE:-}" ] && echo false || echo true)

# The icon is an Icon Composer document (AppIcon.icon). actool only renders it on macOS 26,
# so the rendered output is committed under AppIcon-prebuilt/ and preferred when present —
# CI runs on macos-15, where actool would silently fall back to the flat icns.
# To refresh after editing AppIcon.icon, on macOS 26:
#   xcrun actool AppIcon.icon --compile out --app-icon AppIcon --platform macosx \
#     --minimum-deployment-target 26.0 --output-partial-info-plist out/icon.plist
#   cp out/Assets.car AppIcon-prebuilt/     # then rebuild AppIcon.icns from the render
ICONDIR=$(mktemp -d)
if [ -f AppIcon-prebuilt/AppIcon.icns ]; then
  cp AppIcon-prebuilt/AppIcon.icns "$ICONDIR/AppIcon.icns"
  [ -f AppIcon-prebuilt/Assets.car ] && cp AppIcon-prebuilt/Assets.car "$ICONDIR/Assets.car"
elif [ -d AppIcon.icon ] && xcrun actool AppIcon.icon --compile "$ICONDIR" --app-icon AppIcon \
     --platform macosx --minimum-deployment-target 26.0 \
     --output-partial-info-plist "$ICONDIR/icon.plist" >/dev/null 2>&1 \
     && [ -f "$ICONDIR/AppIcon.icns" ]; then
  :
else
  [ -f AppIcon.icns ] || ./makeicon.sh
  cp AppIcon.icns "$ICONDIR/AppIcon.icns"
fi

# Assets.car is what lets macOS 26 draw and shape the icon itself (found via CFBundleIconName).
# Without it Tahoe adds its own squircle and shadow on top of the already-rounded icns.
ICON_NAME_KEY=""
[ -f "$ICONDIR/Assets.car" ] && ICON_NAME_KEY='  <key>CFBundleIconName</key>          <string>AppIcon</string>'

swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SilentWhisper" "$APP/Contents/MacOS/"
cp "$ICONDIR/AppIcon.icns" "$APP/Contents/Resources/"
[ -f "$ICONDIR/Assets.car" ] && cp "$ICONDIR/Assets.car" "$APP/Contents/Resources/"

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
$ICON_NAME_KEY
  <key>SWDevBuild</key>                <$DEV_BUILD/>
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
