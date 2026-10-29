#!/bin/bash
# Regenerates assets/AppIcon.icns from assets/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O make-icon.swift -o /tmp/sk-make-icon
/tmp/sk-make-icon AppIcon.png
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s AppIcon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) AppIcon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
echo "Done: $PWD/AppIcon.icns"
