#!/bin/bash
# Packs build/MacLinker.app into build/MacLinker.dmg: a styled installer window with a background,
# the app on the left and an Applications shortcut on the right.
# Layout is done by scripting Finder, which needs a logged-in desktop session; if that isn't
# available (for example in CI) a plain, working DMG is produced instead.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/MacLinker.app"
[ -d "$APP" ] || { echo "Run scripts/bundle.sh first"; exit 1; }
[ -f Resources/dmg-background.png ] || swift scripts/make_dmg_background.swift
[ -f Resources/AppIcon.icns ] || swift scripts/make_icon.swift

VOL="MacLinker"
RW="build/MacLinker-rw.dmg"
OUT="build/MacLinker.dmg"
STAGE="$(mktemp -d)"
cleanup() { hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true; rm -rf "$STAGE" "$RW"; }
trap cleanup EXIT
hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp Resources/dmg-background.png "$STAGE/.background/background.png"

rm -f "$RW" "$OUT"
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
hdiutil attach "$RW" -mountpoint "/Volumes/$VOL" -noverify >/dev/null

# Window: 660x400, icon view, big icons, our background; app at left, Applications at right.
if perl -e 'alarm 90; exec @ARGV' osascript 2>"$STAGE/osa.err" >/dev/null <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.png"
    set position of item "MacLinker.app" of container window to {170, 185}
    set position of item "Applications" of container window to {490, 185}
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
then echo "Styled installer window applied."
else echo "Finder layout unavailable ($(head -c 200 "$STAGE/osa.err" 2>/dev/null)); building a plain DMG."; fi

# Finder removes this file while laying out the window, so the disk icon is added afterwards.
cp Resources/AppIcon.icns "/Volumes/$VOL/.VolumeIcon.icns"
SetFile -a C "/Volumes/$VOL" 2>/dev/null || true   # use .VolumeIcon.icns as the disk icon
sync; sleep 1
hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 || hdiutil detach "/Volumes/$VOL" -force >/dev/null
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
echo "Built $OUT"
