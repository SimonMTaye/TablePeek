#!/bin/bash
# Builds TablePeek.app into ./build. Pass --install to copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/TablePeek.app
swift build -c release --product TablePeek
swift build -c release --product tablepeek-cli
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TablePeek" "$APP/Contents/MacOS/TablePeek"
cp "$BIN/tablepeek-cli" "$APP/Contents/MacOS/tablepeek-cli"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Icon (generated once, then cached in Resources/)
if [ ! -f Resources/AppIcon.icns ]; then
  TMP=$(mktemp -d)
  swift scripts/make-icon.swift "$TMP/icon.png"
  mkdir "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/TablePeek.app"
  cp -R "$APP" "$HOME/Applications/"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/TablePeek.app" || true
  echo "Installed to ~/Applications/TablePeek.app"
fi
