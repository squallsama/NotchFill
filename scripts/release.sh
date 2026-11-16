#!/usr/bin/env bash
# Builds a release zip of NotchFill for GitHub Releases.
#
#   scripts/release.sh 0.1.0            -> build/release/NotchFill-0.1.0.zip (+ .sha256)
#   scripts/release.sh 0.1.0 --publish  -> also tag v0.1.0 and create the GitHub release (gh)
#
# Normally CI runs this: .github/workflows/release.yml publishes a release on every push to main.
#
# The app is signed ad-hoc (no Apple Developer ID, not notarized), so on other Macs
# Gatekeeper blocks the first launch; README "Install" explains how to open it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh VERSION [--publish]}"
PUBLISH="${2:-}"
TAG="v$VERSION"
OUT="build/release"
ZIP="$OUT/NotchFill-$VERSION.zip"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean; commit first." >&2
  exit 1
fi

# Ad-hoc signature: the local dev certificate must not end up in a public build.
# Map the source path away so no local directory names land in the binaries.
CODESIGN_IDENTITY="-" SWIFT_EXTRA_FLAGS="-Xswiftc -file-prefix-map -Xswiftc $PWD=." \
  ./scripts/build-app.sh

APP="build/NotchFill.app"
# The linker's debug map (stabs) keeps absolute paths of the build's object files: strip it.
strip -S -x "$APP/Contents/MacOS/NotchFill" "$APP/Contents/MacOS/notchfill-run"
strip -S -x "$APP/Contents/Resources/libNotchFillHook.dylib"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
# Binaries and Info.plist changed: sign again, nested code first (same flags as build-app.sh).
codesign --force --sign - --identifier dev.notchfill.hook "$APP/Contents/Resources/libNotchFillHook.dylib"
codesign --force --sign - --identifier dev.notchfill.run "$APP/Contents/MacOS/notchfill-run"
codesign --force --options runtime --sign - --identifier dev.notchfill.NotchFill "$APP"
codesign --verify --strict --deep "$APP"

if /usr/bin/grep -rl "$HOME" "$APP"; then
  echo "Local path ($HOME) found inside the app bundle; refusing to package." >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "Built $ZIP"
cat "$ZIP.sha256"

if [[ "$PUBLISH" == "--publish" ]]; then
  git tag -a "$TAG" -m "NotchFill $VERSION"
  git push origin "$TAG"
  # Our notes first, then GitHub's list of merged pull requests since the last release.
  gh release create "$TAG" "$ZIP" "$ZIP.sha256" \
    --title "NotchFill $VERSION" \
    --generate-notes \
    --notes-file <(sed "s/@VERSION@/$VERSION/g" scripts/release-notes.md)
fi
