#!/bin/bash
# Builds ShareKeeper.app and packs it into ShareKeeper-<version>.dmg (app + Applications shortcut).
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' ShareKeeper.app/Contents/Info.plist)
DMG="ShareKeeper-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R ShareKeeper.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "ShareKeeper" -srcfolder "$STAGE" -format UDZO -fs HFS+ "$DMG"
echo "Done: $PWD/$DMG"
