#!/usr/bin/env bash
# Sign the freshly-built release archive with Sparkle's EdDSA key and write an
# updated appcast to ./_site/appcast.xml (the workflow then pushes _site/ to the
# gh-pages branch, which GitHub Pages serves at the SUFeedURL in Info.plist).
#
# Expects the artifacts produced by scripts/release-build.sh to already be in
# ./dist/ and the matching GitHub Release (with those assets attached) to exist.
#
# Usage: bash scripts/publish-appcast.sh <version> <build> <tag>
#   <version>  marketing version, e.g. 1.2.0
#   <build>    build number (CURRENT_PROJECT_VERSION) — must be monotonically
#              increasing across releases; Sparkle compares on this
#   <tag>      the git tag, e.g. v1.2.0 (used to build the release asset URL)
#
# Environment:
#   SPARKLE_PRIVATE_ED_KEY   base64 EdDSA private key from Sparkle's
#                            `generate_keys -x <file>` (store as a repo secret)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: publish-appcast.sh <version> <build> <tag>}"
BUILD="${2:?usage: publish-appcast.sh <version> <build> <tag>}"
TAG="${3:?usage: publish-appcast.sh <version> <build> <tag>}"
: "${SPARKLE_PRIVATE_ED_KEY:?SPARKLE_PRIVATE_ED_KEY is not set}"

REPO="rladmsrl/ccbar"
FEED_URL="https://rladmsrl.github.io/ccbar/appcast.xml"
SPARKLE_TOOLS_VERSION="2.9.1"   # the version of sign_update to download; stable across 2.x

# Sparkle updates from a .zip when one is present (no disk image to mount),
# otherwise from the .dmg (notarized + stapled in the signed release path).
ARCHIVE=""
for candidate in "dist/CCBar-$VERSION.zip" "dist/CCBar-$VERSION.dmg"; do
    if [[ -f "$candidate" ]]; then ARCHIVE="$candidate"; break; fi
done
[[ -n "$ARCHIVE" ]] || { echo "error: no dist/CCBar-$VERSION.{zip,dmg} to sign" >&2; exit 1; }
ARCHIVE_NAME="$(basename "$ARCHIVE")"
echo "==> Signing $ARCHIVE for the appcast"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_TOOLS_VERSION}/Sparkle-${SPARKLE_TOOLS_VERSION}.tar.xz" \
    -o "$WORK/sparkle.tar.xz"
tar -xJf "$WORK/sparkle.tar.xz" -C "$WORK" bin/sign_update

KEY_FILE="$WORK/ed_private_key"
printf '%s' "$SPARKLE_PRIVATE_ED_KEY" > "$KEY_FILE"

# sign_update prints: sparkle:edSignature="…" length="…"
ENCLOSURE_ATTRS="$("$WORK/bin/sign_update" "$ARCHIVE" --ed-key-file "$KEY_FILE")"
[[ "$ENCLOSURE_ATTRS" == *edSignature* ]] || { echo "error: sign_update produced no signature: $ENCLOSURE_ATTRS" >&2; exit 1; }

# Start from the currently-published appcast so older versions are preserved.
curl -fsSL "$FEED_URL" -o "$WORK/appcast.xml" || rm -f "$WORK/appcast.xml"

mkdir -p _site
NOTES_FILE="${RELEASE_NOTES_FILE:-release_notes.html}"
[[ -f "$NOTES_FILE" ]] || { echo "error: release notes file '$NOTES_FILE' not found" >&2; exit 1; }

python3 scripts/update-appcast.py \
    --version "$VERSION" \
    --build "$BUILD" \
    --url "https://github.com/$REPO/releases/download/$TAG/$ARCHIVE_NAME" \
    --enclosure-attrs "$ENCLOSURE_ATTRS" \
    --release-notes-file "$NOTES_FILE" \
    --in "$WORK/appcast.xml" \
    --out "_site/appcast.xml"

echo "==> Wrote _site/appcast.xml:"
cat "_site/appcast.xml"
