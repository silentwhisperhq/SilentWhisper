#!/bin/bash
# Cuts a GitHub release the in-app updater can find: ./release.sh 1.0.1
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${1:?usage: ./release.sh <version>}
echo "$VERSION" > VERSION

./build.sh release

ZIP="SilentWhisper-$VERSION.zip"
rm -f "$ZIP"
# ditto, not zip: it preserves the bundle's symlinks and signature.
ditto -c -k --keepParent SilentWhisper.app "$ZIP"

git add -A
git commit -m "Release $VERSION" || true
git tag -f "v$VERSION"
git push origin main --tags --force

gh release create "v$VERSION" "$ZIP" \
  --title "v$VERSION" \
  --notes "Push-to-talk dictation. Hold right ⌥, talk, and the text lands where your cursor is." \
  || gh release upload "v$VERSION" "$ZIP" --clobber

echo "released v$VERSION"
