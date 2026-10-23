#!/bin/bash
# Builds "Codex Gauge.app" and "CodexGauge.dmg" next to this script.
# Xcode is not required; the Command Line Tools are enough.
set -e
cd "$(dirname "$0")"
APP="Codex Gauge.app"; B=build
rm -rf "$B" "$APP"; mkdir -p "$B" "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 Sources/main.swift -o "$B/CodexGauge-arm64"
swiftc -O -swift-version 5 -parse-as-library -target x86_64-apple-macos13.0 Sources/main.swift -o "$B/CodexGauge-x86_64"
lipo -create "$B/CodexGauge-arm64" "$B/CodexGauge-x86_64" -output "$APP/Contents/MacOS/CodexGauge"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O make_icon.swift -o "$B/make_icon" && "$B/make_icon" "$B/icon.png"
mkdir -p "$B/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$B/icon.png" --out "$B/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$B/icon.png" --out "$B/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$B/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep -s - "$APP"
# Drag-to-install disk image.
rm -rf "$B/dmg" CodexGauge.dmg; mkdir -p "$B/dmg"
ditto "$APP" "$B/dmg/$APP"; ln -s /Applications "$B/dmg/Applications"
hdiutil create -quiet -volname "Codex Gauge" -srcfolder "$B/dmg" -ov -format UDZO CodexGauge.dmg
rm -rf "$B"
echo "OK: $(pwd)/$APP"
echo "OK: $(pwd)/CodexGauge.dmg"
