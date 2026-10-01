#!/bin/bash
# Packs build/MacLinker.app into build/MacLinker.dmg (drag-to-Applications installer).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/MacLinker.app"
[ -d "$APP" ] || { echo "Run scripts/bundle.sh first"; exit 1; }
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f build/MacLinker.dmg
hdiutil create -volname "MacLinker" -srcfolder "$STAGE" -ov -format UDZO build/MacLinker.dmg >/dev/null
echo "Built build/MacLinker.dmg"
