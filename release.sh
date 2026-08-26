#!/bin/bash
#
# LiveWall — build, sign, zip, and publish a GitHub release in one command.
#
#   ./release.sh 1.6.27
#
# After this runs, anyone on an older version who clicks "Check for Updates"
# in LiveWall gets the update popup and can download it.
#
# ONE-TIME SETUP (only needed once, and only you can do it — it's your GitHub):
#   1. Install the GitHub CLI:
#        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
#        brew install gh
#      (or download from https://cli.github.com)
#   2. Log in once:
#        gh auth login
#      Choose GitHub.com → HTTPS → log in with a browser. gh stores the token in
#      your macOS keychain; this script never sees it.
#
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: ./release.sh <version>   e.g. ./release.sh 1.6.27"
  exit 1
fi
BUILD="${VERSION//./}"          # 1.6.27 -> 1627-ish build number
TAG="v$VERSION"
ZIP="LiveWall-$VERSION.zip"

command -v gh >/dev/null || { echo "❌ gh not installed — see ONE-TIME SETUP at the top of this script."; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "❌ Not logged in. Run: gh auth login"; exit 1; }

echo "▶︎ Building release $VERSION…"
swift build -c release
cp .build/release/LiveWall LiveWall.app/Contents/MacOS/LiveWall
plutil -replace CFBundleShortVersionString -string "$VERSION" LiveWall.app/Contents/Info.plist
plutil -replace CFBundleVersion -string "$BUILD" LiveWall.app/Contents/Info.plist
codesign --force --deep --sign - LiveWall.app
codesign --verify --strict LiveWall.app && echo "  signature OK"

echo "▶︎ Packaging $ZIP…"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent LiveWall.app "$ZIP"

echo "▶︎ Publishing GitHub release $TAG…"
# --generate-notes writes a changelog from commits; --clobber replaces if the tag exists.
gh release create "$TAG" "$ZIP" \
  --title "LiveWall $VERSION" \
  --notes "LiveWall $VERSION. Download the zip below, unzip, and move LiveWall.app to Applications." \
  || gh release upload "$TAG" "$ZIP" --clobber

echo "✅ Published $TAG. Older installs will now see the update popup."
