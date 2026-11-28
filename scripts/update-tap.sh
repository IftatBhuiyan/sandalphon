#!/bin/bash
# Points the Homebrew cask in IftatBhuiyan/homebrew-tap at a published release. release.sh runs it after
# publishing; it can be run again by hand.  Usage: scripts/update-tap.sh [VERSION]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-$(cat VERSION)}"
REPO="${SANDALPHON_REPO:-IftatBhuiyan/sandalphon}"
TAP="${SANDALPHON_TAP:-IftatBhuiyan/homebrew-tap}"
URL="https://github.com/$REPO/releases/download/v$VERSION/Sandalphon-$VERSION.dmg"

# Hash what users will actually download, not the local build.
SHA="$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)"
[[ ${#SHA} == 64 ]] || { echo "could not download $URL" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$TAP" "$WORK/tap" -- --quiet
CASK="$WORK/tap/Casks/sandalphon.rb"
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
cd "$WORK/tap"
if git diff --quiet; then echo "tap already at $VERSION"; exit 0; fi
git commit -qam "sandalphon $VERSION"
git push -q
echo "tap updated: sandalphon $VERSION ($SHA)"
