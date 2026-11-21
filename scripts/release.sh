#!/bin/bash
# Builds an Apple Silicon TablePeek.app and zips it into build/TablePeek-<version>.zip.
#   scripts/release.sh            build + zip only
#   scripts/release.sh --publish  also create a GitHub release (tag v<version>) with the zip attached
# The app is signed ad hoc (no Apple Developer ID), so it isn't notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
ZIP="build/TablePeek-$VERSION.zip"

./scripts/build-app.sh
lipo -archs build/TablePeek.app/Contents/MacOS/TablePeek
codesign --verify --deep --strict build/TablePeek.app
rm -f "$ZIP"
ditto -c -k --keepParent --sequesterRsrc build/TablePeek.app "$ZIP"
echo "Wrote $ZIP ($(du -h "$ZIP" | cut -f1))"

if [ "${1:-}" = "--publish" ]; then
  NOTES=$(mktemp)
  sed "s/VERSION/$VERSION/g" scripts/release-notes.md > "$NOTES"
  gh release create "v$VERSION" "$ZIP" --title "TablePeek $VERSION" --notes-file "$NOTES"
  rm -f "$NOTES"
fi
