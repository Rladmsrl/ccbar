#!/usr/bin/env bash
# Copy non-system dylib dependencies into GitTools/runtime/lib and rewrite Mach-O
# references so the runtime can move inside the app bundle.
set -euo pipefail

ROOT="${1:-}"
[[ -n "$ROOT" ]] || { echo "usage: $0 <gittools-runtime-dir>" >&2; exit 2; }
[[ -d "$ROOT" ]] || { echo "error: runtime dir not found: $ROOT" >&2; exit 1; }

ROOT="$(cd "$ROOT" && pwd)"
LIB_DIR="$ROOT/runtime/lib"
mkdir -p "$LIB_DIR"

is_macho() {
    [[ -f "$1" ]] && file "$1" | grep -q "Mach-O"
}

is_system_ref() {
    case "$1" in
        @rpath/*|@loader_path/*|@executable_path/*|/usr/lib/*|/System/Library/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

relative_from_file_to_lib() {
    local item="$1"
    /usr/bin/ruby -rpathname -e '
        lib = Pathname.new(ARGV[0]).realpath
        base = Pathname.new(ARGV[1]).dirname.realpath
        puts lib.relative_path_from(base)
    ' "$LIB_DIR" "$item"
}

copy_dependency() {
    local dep="$1"
    [[ -f "$dep" ]] || return 1

    local base dest
    base="$(basename "$dep")"
    dest="$LIB_DIR/$base"
    if [[ ! -e "$dest" ]]; then
        cp -pL "$dep" "$dest"
        chmod u+w "$dest"
        return 0
    fi
    return 1
}

add_rpath_once() {
    local item="$1"
    local rpath="$2"
    if ! otool -l "$item" | grep -Fq "$rpath"; then
        install_name_tool -add_rpath "$rpath" "$item" 2>/dev/null || true
    fi
}

patch_item() {
    local item="$1"
    local rel rpath dep base
    rel="$(relative_from_file_to_lib "$item")"
    rpath="@loader_path/$rel"
    add_rpath_once "$item" "$rpath"

    if [[ "$item" == *.dylib ]]; then
        install_name_tool -id "@rpath/$(basename "$item")" "$item" 2>/dev/null || true
    fi

    while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        is_system_ref "$dep" && continue
        [[ "$dep" == "$item" ]] && continue
        if [[ "$dep" == /* ]]; then
            base="$(basename "$dep")"
            install_name_tool -change "$dep" "@rpath/$base" "$item" 2>/dev/null || true
        fi
    done < <(otool -L "$item" | sed '1d' | awk '{print $1}')
}

# Copy dependencies recursively until no new non-system dylibs appear.
for _ in 1 2 3 4 5 6 7 8; do
    copied=0
    while IFS= read -r -d '' item; do
        is_macho "$item" || continue
        while IFS= read -r dep; do
            [[ -n "$dep" ]] || continue
            is_system_ref "$dep" && continue
            [[ "$dep" == "$item" ]] && continue
            if [[ "$dep" == /* ]]; then
                if copy_dependency "$dep"; then
                    copied=1
                fi
            fi
        done < <(otool -L "$item" | sed '1d' | awk '{print $1}')
    done < <(find "$ROOT" -type f -print0)
    [[ "$copied" -eq 0 ]] && break
done

while IFS= read -r -d '' item; do
    is_macho "$item" || continue
    patch_item "$item"
done < <(find "$ROOT" -type f -print0)
