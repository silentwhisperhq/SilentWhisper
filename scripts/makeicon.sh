#!/bin/bash
# Renders icon.swift into AppIcon.icns at every size macOS asks for.
set -euo pipefail
cd "$(dirname "$0")/.."

SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"

for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" "256 128x128@2x" \
            "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
  set -- $spec
  swift scripts/icon.swift "$1" "$SET/icon_$2.png"
done

iconutil -c icns "$SET" -o AppIcon.icns
echo "wrote AppIcon.icns"
