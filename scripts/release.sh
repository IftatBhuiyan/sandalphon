#!/bin/bash
# Publishes the version in VERSION as a GitHub release. See RELEASING.md.
#   scripts/release.sh            build, notarize, tag and publish
#   scripts/release.sh --dry-run  everything except tagging and publishing
set -euo pipefail
cd "$(dirname "$0")/.."

DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
VERSION="$(cat VERSION)"
TAG="v$VERSION"
REPO="${SANDALPHON_REPO:-IftatBhuiyan/sandalphon}"
KEY="${SANDALPHON_UPDATE_KEY:-$HOME/.config/sandalphon/sparkle_ed25519_private.key}"
DMG="build/Sandalphon-$VERSION.dmg"

[[ -f "$KEY" ]] || { echo "update signing key not found at $KEY" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "commit or stash your changes first" >&2; exit 1; }
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "CHANGELOG.md has no section for $VERSION" >&2; exit 1; }
# A tag left by a run that failed before publishing is fine, as long as it is this commit and unpublished.
if [[ $DRY == 0 ]] && git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  [[ "$(git rev-parse "$TAG^{commit}")" == "$(git rev-parse HEAD)" ]] || { echo "$TAG exists on another commit" >&2; exit 1; }
  ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 || { echo "$TAG is already published" >&2; exit 1; }
fi

swift test -c release
scripts/build-app.sh --universal --notarize

# Release notes: this version's section of the changelog.
NOTES="$(awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {on=1; next} /^## \[/ {on=0} on' CHANGELOG.md)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/Sandalphon.app/Contents/Info.plist)"
SIGNATURE="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --ed-key-file "$KEY" "$DMG")"

cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Sandalphon</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/Sandalphon-$VERSION.dmg"
                 type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
echo "wrote build/appcast.xml"

if [[ $DRY == 1 ]]; then echo "dry run: not tagging or publishing"; exit 0; fi
# Safe to run again if publishing failed after the tag was pushed.
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "Sandalphon $VERSION"
git push origin "$TAG"
# A copy under a fixed name, so the website can link to releases/latest/download/Sandalphon.dmg.
cp "$DMG" build/Sandalphon.dmg
gh release create "$TAG" "$DMG" build/Sandalphon.dmg build/appcast.xml --repo "$REPO" --title "Sandalphon $VERSION" --notes "$NOTES"
echo "published https://github.com/$REPO/releases/tag/$TAG"
# Homebrew. The release is already public, so a failure here must not look like a failed release.
scripts/update-tap.sh "$VERSION" || echo "WARNING: the Homebrew tap was not updated; run scripts/update-tap.sh $VERSION" >&2
