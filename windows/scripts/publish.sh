#!/bin/bash
# Builds the Windows app from macOS or Linux (or Windows with Git Bash): self-contained single-file executables that need
# no .NET install, zipped into build/ as MacLinker-Windows-x64.zip and MacLinker-Windows-arm64.zip.
# Usage: windows/scripts/publish.sh [version]
set -euo pipefail
cd "$(dirname "$0")/../.."
VERSION="${1:-0.1.0}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
python3 windows/scripts/make_ico.py >/dev/null 2>&1 || true     # icon comes from the Mac build's icon set when present
mkdir -p build
for RID in win-x64 win-arm64; do
  OUT="$(mktemp -d)"
  dotnet publish windows/src/MacLinker.Windows -c Release -r "$RID" --self-contained \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true \
    -p:Version="$VERSION" -p:EnableWindowsTargeting=true -o "$OUT" >/dev/null
  NAME="MacLinker-Windows-${RID#win-}.zip"
  rm -f "build/$NAME"
  (cd "$OUT" && zip -q -9 "$OLDPWD/build/$NAME" MacLinker.exe)
  rm -rf "$OUT"
  echo "Built build/$NAME"
done
