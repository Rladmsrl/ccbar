#!/usr/bin/env bash
# Verify that a GitTools runtime works after relocation and does not retain
# Homebrew or CI build-path dynamic library references.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="${1:-}"
[[ -n "$SOURCE" ]] || { echo "usage: $0 <gittools-runtime-dir>" >&2; exit 2; }
[[ -d "$SOURCE" ]] || { echo "error: runtime dir not found: $SOURCE" >&2; exit 1; }

SOURCE="$(cd "$SOURCE" && pwd)"
[[ -x "$SOURCE/bin/github-linguist" ]] || { echo "error: missing executable bin/github-linguist" >&2; exit 1; }
[[ -x "$SOURCE/bin/scc" ]] || { echo "error: missing executable bin/scc" >&2; exit 1; }
if find "$SOURCE" -type d -name '*.dSYM' -print -quit | grep -q .; then
    echo "error: GitTools runtime contains debug symbol bundles; prune them before packaging" >&2
    exit 1
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gittools-verify.XXXXXX")"
cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

RELOCATED="$TMP_ROOT/Relocated GitTools"
cp -R "$SOURCE" "$RELOCATED"

FIXTURE_SOURCE="$PWD/scripts/gittools/fixtures/mini-repo"
FIXTURE="$TMP_ROOT/mini-repo"
cp -R "$FIXTURE_SOURCE" "$FIXTURE"
git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.email "gittools-runtime@example.invalid"
git -C "$FIXTURE" config user.name "GitTools Runtime"
git -C "$FIXTURE" config commit.gpgsign false
git -C "$FIXTURE" add .
git -C "$FIXTURE" commit -qm "fixture"

LINGUIST_JSON="$TMP_ROOT/linguist.json"
SCC_JSON="$TMP_ROOT/scc.json"

"$RELOCATED/bin/github-linguist" --breakdown --json --tree-size=1000000 "$FIXTURE" > "$LINGUIST_JSON"
"$RELOCATED/bin/scc" --format json --by-file "$FIXTURE" > "$SCC_JSON"

/usr/bin/ruby -rjson -e '
  data = JSON.parse(File.read(ARGV.fetch(0)))
  abort "missing Swift from Linguist output" unless data.key?("Swift")
  abort "missing Ruby from Linguist output" unless data.key?("Ruby")
' "$LINGUIST_JSON"

/usr/bin/ruby -rjson -e '
  rows = JSON.parse(File.read(ARGV.fetch(0)))
  names = rows.map { |row| row["Name"] }
  abort "missing Swift from scc output" unless names.include?("Swift")
  abort "missing Ruby from scc output" unless names.include?("Ruby")
' "$SCC_JSON"

is_macho() {
    [[ -f "$1" ]] && file "$1" | grep -q "Mach-O"
}

while IFS= read -r -d '' item; do
    is_macho "$item" || continue
    while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        case "$dep" in
            @rpath/*|@loader_path/*|@executable_path/*|/usr/lib/*|/System/Library/*)
                ;;
            /*)
                echo "error: non-relocatable Mach-O reference in $item: $dep" >&2
                exit 1
                ;;
        esac
    done < <(otool -L "$item" | sed '1d' | awk '{print $1}')
done < <(find "$RELOCATED" -type d -name '*.dSYM' -prune -o -type f -print0)

echo "GitTools runtime verified: $SOURCE"
