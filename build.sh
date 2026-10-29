#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP=ShareKeeper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 Sources/Core/*.swift Sources/App/main.swift -o "$APP/Contents/MacOS/ShareKeeper"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>nl.david.ShareKeeper</string>
<key>CFBundleName</key><string>ShareKeeper</string>
<key>CFBundleExecutable</key><string>ShareKeeper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>LSUIElement</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>ShareKeeper finds your other Macs running ShareKeeper and connects to them to share folders.</string>
<key>NSBonjourServices</key><array><string>_sharekeeper._tcp</string></array>
</dict></plist>
EOF
# Stable certificate so the Local Network permission survives a rebuild (ad-hoc = new
# cdhash per build). Create via Certificate Assistant (Code Signing, self-signed).
IDENTITY="ShareKeeper Dev"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "Note: certificate '$IDENTITY' not found, signed ad-hoc (Local Network permission may be asked again after a rebuild)"
    codesign --force --sign - "$APP"
fi
echo "Done: $PWD/$APP"
