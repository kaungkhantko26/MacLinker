#!/bin/bash
# Builds MacLinker and wraps it in a signed .app bundle at build/MacLinker.app
#   MACLINKER_VERSION        version to stamp (default 1.0.0)
#   MACLINKER_REPO           GitHub "owner/repo" that hosts releases (enables auto-update)
#   MACLINKER_SIGN_IDENTITY  signing identity (default "MacLinker Dev" from scripts/setup_signing.sh; use "-" for ad-hoc)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${MACLINKER_VERSION:-1.0.0}"
REPO="${MACLINKER_REPO:-$(cat .maclinker-repo 2>/dev/null || true)}"
IDENTITY="${MACLINKER_SIGN_IDENTITY:-MacLinker Dev}"
# Universal binary: runs natively on Apple Silicon and Intel Macs.
ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/MacLinker"
APP="build/MacLinker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacLinker"
sed -e "s|__VERSION__|$VERSION|" -e "s|__REPO__|$REPO|" Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] || swift scripts/make_icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$IDENTITY" --identifier com.maclinker.app "$APP"
(cd build && rm -f MacLinker.zip && ditto -c -k --keepParent MacLinker.app MacLinker.zip)
echo "Built $APP v$VERSION signed as '$IDENTITY' -> build/MacLinker.zip"
