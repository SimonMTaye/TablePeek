#!/bin/bash
# Builds TablePeek.app into ./build.
#   --install    also copy it to ~/Applications and register the Quick Look extension
#   --universal  build for both arm64 and x86_64 (used for releases)
set -euo pipefail
INSTALL=0; ARCHS=("$(uname -m)")
for a in "$@"; do
  case "$a" in
    --install) INSTALL=1 ;;
    --universal) ARCHS=(arm64 x86_64) ;;
    *) echo "unknown option $a" >&2; exit 1 ;;
  esac
done
export PATH="/Library/TeX/texbin:$PATH"
cd "$(dirname "$0")/.."

APP=build/TablePeek.app
TMPBIN=$(mktemp -d)
for arch in "${ARCHS[@]}"; do
  swift build -c release --arch "$arch" --product TablePeek
  swift build -c release --arch "$arch" --product tablepeek-cli
  BIN=$(swift build -c release --arch "$arch" --show-bin-path)
  cp "$BIN/TablePeek" "$TMPBIN/TablePeek-$arch"
  cp "$BIN/tablepeek-cli" "$TMPBIN/tablepeek-cli-$arch"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$TMPBIN"/TablePeek-* -output "$APP/Contents/MacOS/TablePeek"
lipo -create "$TMPBIN"/tablepeek-cli-* -output "$APP/Contents/MacOS/tablepeek-cli"
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

# Quick Look extension (Finder spacebar preview). Built with plain swiftc so Xcode isn't needed.
APPEX="$APP/Contents/PlugIns/TablePeekQL.appex"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
cp QuickLook/Info.plist "$APPEX/Contents/Info.plist"
for arch in "${ARCHS[@]}"; do
  swiftc -O -module-name TablePeekQL -parse-as-library -application-extension \
    -target "$arch-apple-macos14.0" -sdk "$(xcrun --show-sdk-path)" \
    Sources/TablePeekCore/LatexScanner.swift Sources/TablePeekCore/InlineConverter.swift \
    Sources/TablePeekCore/TableParser.swift Sources/TablePeekCore/HTMLRenderer.swift \
    QuickLook/PreviewProvider.swift \
    -framework QuickLookUI -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$TMPBIN/TablePeekQL-$arch"
done
lipo -create "$TMPBIN"/TablePeekQL-* -output "$APPEX/Contents/MacOS/TablePeekQL"
rm -rf "$TMPBIN"
LM=$(dirname "$(kpsewhich lmroman10-regular.otf 2>/dev/null || echo /Library/TeX/Root/texmf-dist/fonts/opentype/public/lm/x)")
for f in lmroman10-regular lmroman10-bold lmroman10-italic lmroman10-bolditalic lmmono10-regular; do
  [ -f "$LM/$f.otf" ] && cp "$LM/$f.otf" "$APPEX/Contents/Resources/" && cp "$LM/$f.otf" "$APP/Contents/Resources/"
done

# Ad-hoc signing ("Sign to Run Locally"); the extension must be sandboxed.
codesign --force --sign - "$APP/Contents/MacOS/tablepeek-cli"
codesign --force --sign - --entitlements QuickLook/QuickLook.entitlements "$APPEX"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "$INSTALL" = 1 ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/TablePeek.app"
  cp -R "$APP" "$HOME/Applications/"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/TablePeek.app" || true
  pluginkit -a "$HOME/Applications/TablePeek.app/Contents/PlugIns/TablePeekQL.appex" 2>/dev/null || true
  qlmanage -r >/dev/null 2>&1 || true
  echo "Installed to ~/Applications/TablePeek.app"
fi
