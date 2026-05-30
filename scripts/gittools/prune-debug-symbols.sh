#!/usr/bin/env bash
# Remove debug symbol bundles from the redistributable GitTools runtime.
#
# Ruby and native gems can leave *.dSYM directories next to compiled extension
# bundles. They are large, not needed at runtime, and should not be codesigned or
# shipped inside the app bundle.
set -euo pipefail

ROOT="${1:-}"
[[ -n "$ROOT" ]] || { echo "usage: $0 <gittools-runtime-dir>" >&2; exit 2; }
[[ -d "$ROOT" ]] || { echo "error: runtime dir not found: $ROOT" >&2; exit 1; }

removed=0
while IFS= read -r -d '' item; do
    rm -rf "$item"
    removed=$((removed + 1))
done < <(find "$ROOT" -type d -name '*.dSYM' -prune -print0)

if [[ "$removed" -gt 0 ]]; then
    echo "Pruned $removed debug symbol bundle(s) from GitTools runtime"
fi
