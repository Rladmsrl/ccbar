#!/usr/bin/env bash
# Update the version numbers in project.yml.
#
# Usage: bash scripts/bump-version.sh <marketing-version> [build-number]
#   <marketing-version>  e.g. 1.2.0   -> MARKETING_VERSION (CFBundleShortVersionString)
#   [build-number]       e.g. 42      -> CURRENT_PROJECT_VERSION (CFBundleVersion); defaults to 1
#
# Pure text substitution — no yq/yaml dependency. Run scripts/generate.sh afterwards
# to regenerate ClaudeStats.xcodeproj.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
BUILD="${2:-1}"

if [[ -z "$VERSION" ]]; then
    echo "usage: bash scripts/bump-version.sh <marketing-version> [build-number]" >&2
    exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: marketing version must look like 1.2.0 (got: $VERSION)" >&2
    exit 2
fi
if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "error: build number must be a positive integer (got: $BUILD)" >&2
    exit 2
fi

# BSD sed (macOS) and GNU sed (Linux CI runners) both accept `-i.bak ... && rm`.
sed -i.bak -E \
    -e "s/^([[:space:]]*MARKETING_VERSION:)[[:space:]]*\".*\"/\1 \"$VERSION\"/" \
    -e "s/^([[:space:]]*CURRENT_PROJECT_VERSION:)[[:space:]]*\".*\"/\1 \"$BUILD\"/" \
    project.yml
rm -f project.yml.bak

echo "project.yml -> MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$BUILD"
grep -E "MARKETING_VERSION|CURRENT_PROJECT_VERSION" project.yml
