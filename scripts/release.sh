#!/bin/bash
# Cuts a GitHub release the in-app updater can find: ./release.sh 1.0.1
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version>}
echo "$VERSION" > VERSION

SW_RELEASE=1 scripts/build.sh release

ZIP="SilentWhisper-$VERSION.zip"
rm -f "$ZIP"
# ditto, not zip: it preserves the bundle's symlinks and signature.
ditto -c -k --keepParent SilentWhisper.app "$ZIP"

# Notarize when a keychain profile exists, so other people can open the app without
# Gatekeeper blocking it. Set up once with:
#   xcrun notarytool store-credentials silentwhisper --apple-id <id> --team-id <team> --password <app-specific-password>
NOTARIZED=no
if xcrun notarytool history --keychain-profile silentwhisper >/dev/null 2>&1; then
  echo "notarizing…"
  if xcrun notarytool submit "$ZIP" --keychain-profile silentwhisper --wait; then
    # The staple goes on the app, then the zip is rebuilt so the ticket ships with it.
    xcrun stapler staple SilentWhisper.app
    rm -f "$ZIP"
    ditto -c -k --keepParent SilentWhisper.app "$ZIP"
    NOTARIZED=yes
  fi
fi

# The DMG is the human download; the zip stays for the in-app updater.
scripts/makedmg.sh
DMG="SilentWhisper-$VERSION.dmg"
if [ "$NOTARIZED" = yes ]; then
  xcrun notarytool submit "$DMG" --keychain-profile silentwhisper --wait
  xcrun stapler staple "$DMG"
fi

git add -A
git commit -m "Release $VERSION" || true
git tag -f "v$VERSION"
git push origin main --tags --force

gh release create "v$VERSION" "$DMG" "$ZIP" \
  --title "v$VERSION" \
  --notes "Push-to-talk dictation. Hold right ⌥, talk, and the text lands where your cursor is.

Download the **.dmg** and drag Silent Whisper to Applications. The .zip is what the in-app updater uses." \
  || gh release upload "v$VERSION" "$DMG" "$ZIP" --clobber

echo
echo "──────────────────────────────────────────────"
echo "released v$VERSION"
SIGNER=$(codesign -dv SilentWhisper.app 2>&1 | grep -E "^Authority=" | head -1 | cut -d= -f2-)
echo "signed by:  ${SIGNER:-ad-hoc (no certificate)}"
if [ "$NOTARIZED" = yes ]; then
  echo "notarized:  yes — opens cleanly on any Mac"
else
  echo "notarized:  NO"
  echo
  echo "  Anyone downloading this will be blocked by Gatekeeper, and your own"
  echo "  Accessibility grant dies on every update. To fix, once:"
  echo "    1. Xcode > Settings > Accounts > sign in > Manage Certificates >"
  echo "       + > Developer ID Application"
  echo "    2. xcrun notarytool store-credentials silentwhisper \\"
  echo "         --apple-id <you@example.com> --team-id <TEAMID> \\"
  echo "         --password <app-specific-password from appleid.apple.com>"
fi
echo "──────────────────────────────────────────────"
