#!/bin/bash
# Usage: scripts/release.sh 1.0.1
# Builds, signs and publishes build/MacLinker.zip as a GitHub release. MacLinker on your Macs then
# finds it automatically. Needs the repo in .maclinker-repo (owner/repo) and the `gh` CLI, or upload by hand.
set -euo pipefail
cd "$(dirname "$0")/.."
V="${1:?usage: release.sh <version>}"
MACLINKER_VERSION="$V" ./scripts/bundle.sh
REPO="$(cat .maclinker-repo)"
if command -v gh >/dev/null; then
  gh release create "v$V" build/MacLinker.zip --repo "$REPO" --title "MacLinker $V" --notes "MacLinker $V"
else
  echo "gh not installed. Create a release tagged v$V at https://github.com/$REPO/releases/new"
  echo "and attach build/MacLinker.zip (it must be named MacLinker.zip)."
fi
