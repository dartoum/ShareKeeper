#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP=ShareKeeper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -swift-version 5 Sources/Core/*.swift Sources/App/main.swift -o "$APP/Contents/MacOS/ShareKeeper"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>nl.david.ShareKeeper</string>
<key>CFBundleName</key><string>ShareKeeper</string>
<key>CFBundleExecutable</key><string>ShareKeeper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSLocalNetworkUsageDescription</key><string>ShareKeeper finds your other Macs running ShareKeeper and connects to them to share folders.</string>
<key>NSBonjourServices</key><array><string>_sharekeeper._tcp</string></array>
</dict></plist>
EOF
# Signing, best identity first (override with SIGN_IDENTITY="name or hash"):
#   Developer ID Application  - the only one Gatekeeper accepts on other Macs (needs a paid developer
#                               account; add notarization for no warning at all, see AGENTS.md)
#   Apple Development         - stable identity: Local Network permission survives rebuilds, but
#                               Gatekeeper on another Mac still asks for right-click -> Open
#   ad-hoc                    - last resort; the permission is asked again after every rebuild
LIST=$(security find-identity -v -p codesigning 2>/dev/null || true)
pick() { echo "$LIST" | grep "$1" | head -1 | sed -E 's/^ *[0-9]+\) ([0-9A-F]{40}) .*/\1/' || true; }
IDENTITY="${SIGN_IDENTITY:-$(pick 'Developer ID Application')}"
[ -n "$IDENTITY" ] || IDENTITY=$(pick 'Apple Development')
if [ -n "$IDENTITY" ]; then
    OPTS=()
    if echo "$LIST" | grep "$IDENTITY" | grep -q 'Developer ID'; then OPTS=(--options runtime --timestamp); fi
    codesign --force ${OPTS[@]+"${OPTS[@]}"} --sign "$IDENTITY" "$APP"
    echo "Signed with: $(codesign -dvv "$APP" 2>&1 | grep '^Authority=' | head -1)"
else
    echo "Note: no signing identity found, signed ad-hoc (Local Network permission is asked again after a rebuild)"
    codesign --force --sign - "$APP"
fi
echo "Done: $PWD/$APP"
