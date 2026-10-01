#!/bin/bash
# Usage: scripts/release.sh 1.0.1
# Builds, signs and publishes a GitHub release with MacLinker.zip (used by the in-app updater)
# and MacLinker.dmg (for humans), and refreshes the Homebrew cask. Needs the `gh` CLI, logged in.
set -euo pipefail
cd "$(dirname "$0")/.."
V="${1:?usage: release.sh <version>}"
REPO="$(cat .maclinker-repo)"
MACLINKER_VERSION="$V" ./scripts/bundle.sh
./scripts/make_dmg.sh
SHA="$(shasum -a 256 build/MacLinker.zip | awk '{print $1}')"
sed -i '' -e "s/^  version \".*\"/  version \"$V\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/maclinker.rb
gh release create "v$V" build/MacLinker.zip build/MacLinker.dmg --repo "$REPO" --title "MacLinker $V" --generate-notes
echo "Released v$V. Commit and push Casks/maclinker.rb so 'brew install' picks up the new version."
