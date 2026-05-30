#!/usr/bin/env bash
# Prepare the app-bundled Git language statistics runtime.
#
# Normal debug/test builds are allowed to continue without the runtime; the app
# then shows an unavailable state in Repo Inspector. Set REQUIRE_LINGUIST_RUNTIME=1
# for release packaging so missing tools fail loudly.
#
# Supported inputs:
#   LINGUIST_RUNTIME_SOURCE=/path/to/runtime
#     Copies a prebuilt runtime directory containing bin/github-linguist and
#     bin/scc. If the source contains manifest.json, it is preserved.
#
#   INSTALL_LINGUIST_RUNTIME=1
#     Installs github-linguist into ClaudeStats/Resources/GitTools/gems using
#     Homebrew Ruby when available, and creates a wrapper in bin/github-linguist.
#     This is useful for local development only. A fully redistributable release
#     must provide a relocatable runtime source.
set -euo pipefail
cd "$(dirname "$0")/.."

TOOLS_DIR="$PWD/ClaudeStats/Resources/GitTools"
BIN_DIR="$TOOLS_DIR/bin"
GEMS_DIR="$TOOLS_DIR/gems"
MANIFEST="$TOOLS_DIR/manifest.json"
LINGUIST_VERSION="${LINGUIST_VERSION:-9.5.0}"
RUNTIME_KIND="none"

mkdir -p "$BIN_DIR" "$GEMS_DIR"

brew_prefix() {
    brew --prefix "$1" 2>/dev/null || true
}

reset_runtime_payload() {
    find "$BIN_DIR" -mindepth 1 ! -name ".gitkeep" -exec rm -rf {} +
    rm -rf "$GEMS_DIR" "$TOOLS_DIR/runtime"
    mkdir -p "$BIN_DIR" "$GEMS_DIR"
}

write_manifest() {
    local linguist="$1"
    local scc="$2"
    cat > "$MANIFEST" <<JSON
{
  "githubLinguist": "$linguist",
  "scc": "$scc",
  "linguistVersion": "$LINGUIST_VERSION",
  "runtimeKind": "$RUNTIME_KIND"
}
JSON
}

if [[ -n "${LINGUIST_RUNTIME_SOURCE:-}" ]]; then
    if [[ ! -x "$LINGUIST_RUNTIME_SOURCE/bin/github-linguist" || ! -x "$LINGUIST_RUNTIME_SOURCE/bin/scc" ]]; then
        echo "error: LINGUIST_RUNTIME_SOURCE must contain executable bin/github-linguist and bin/scc" >&2
        exit 1
    fi
    reset_runtime_payload
    rsync -a "$LINGUIST_RUNTIME_SOURCE/" "$TOOLS_DIR/"
    bash scripts/gittools/prune-debug-symbols.sh "$TOOLS_DIR"
    RUNTIME_KIND="prebuilt"
    if [[ ! -f "$MANIFEST" ]]; then
        write_manifest "bundled" "bundled"
    fi
    echo "Prepared GitTools from $LINGUIST_RUNTIME_SOURCE"
    exit 0
fi

install_linguist_gem() {
    local ruby_bin="${RUBY_BIN:-}"
    local missing_tools=()
    if [[ -z "$ruby_bin" && -x /opt/homebrew/opt/ruby/bin/ruby ]]; then
        ruby_bin=/opt/homebrew/opt/ruby/bin/ruby
    fi
    if [[ -z "$ruby_bin" && -x /usr/local/opt/ruby/bin/ruby ]]; then
        ruby_bin=/usr/local/opt/ruby/bin/ruby
    fi
    if [[ -z "$ruby_bin" ]]; then
        echo "error: Homebrew Ruby not found; install ruby or set RUBY_BIN" >&2
        echo "hint: brew install ruby scc cmake pkg-config icu4c" >&2
        exit 1
    fi

    command -v cmake >/dev/null 2>&1 || missing_tools+=(cmake)
    command -v pkg-config >/dev/null 2>&1 || missing_tools+=(pkg-config)
    if [[ "${#missing_tools[@]}" -gt 0 ]]; then
        echo "error: github-linguist native gems need: ${missing_tools[*]}" >&2
        echo "hint: brew install ruby scc cmake pkg-config icu4c" >&2
        exit 1
    fi

    local icu_prefix
    icu_prefix="$(brew_prefix icu4c)"
    if [[ -z "$icu_prefix" ]]; then
        icu_prefix="$(brew_prefix icu4c@78)"
    fi

    rm -rf "$GEMS_DIR"
    mkdir -p "$GEMS_DIR"

    export GEM_HOME="$GEMS_DIR"
    export GEM_PATH="$GEMS_DIR"
    if [[ -n "$icu_prefix" ]]; then
        export PKG_CONFIG_PATH="$icu_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    fi

    local gem_args=(--install-dir "$GEMS_DIR" --bindir "$GEMS_DIR/bin" --no-document)
    if [[ -n "$icu_prefix" ]]; then
        "$ruby_bin" -S gem install charlock_holmes -v 0.7.9 "${gem_args[@]}" -- --with-icu-dir="$icu_prefix"
    fi
    "$ruby_bin" -S gem install rugged -v 1.9.0 "${gem_args[@]}"
    "$ruby_bin" -S gem install github-linguist \
        -v "$LINGUIST_VERSION" \
        "${gem_args[@]}"

    cat > "$BIN_DIR/github-linguist" <<SH
#!/usr/bin/env bash
set -euo pipefail
export GEM_HOME="\$(cd "\$(dirname "\$0")/../gems" && pwd)"
export GEM_PATH="\$GEM_HOME"
export PATH="\$GEM_HOME/bin:/opt/homebrew/opt/ruby/bin:/usr/local/opt/ruby/bin:/usr/bin:/bin:/usr/sbin:/sbin"
exec "$ruby_bin" "\$GEM_HOME/bin/github-linguist" "\$@"
SH
    chmod +x "$BIN_DIR/github-linguist"
    RUNTIME_KIND="development"
}

if [[ "${INSTALL_LINGUIST_RUNTIME:-0}" == "1" && ! -x "$BIN_DIR/github-linguist" ]]; then
    install_linguist_gem
fi

if [[ ! -x "$BIN_DIR/github-linguist" ]]; then
    if command -v github-linguist >/dev/null 2>&1; then
        cat > "$BIN_DIR/github-linguist" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exec "$(command -v github-linguist)" "$@"
SH
        chmod +x "$BIN_DIR/github-linguist"
        RUNTIME_KIND="development"
    fi
fi

if [[ ! -x "$BIN_DIR/scc" ]]; then
    if command -v scc >/dev/null 2>&1; then
        cp "$(command -v scc)" "$BIN_DIR/scc"
        chmod +x "$BIN_DIR/scc"
    fi
fi

LINGUIST_STATE="missing"
SCC_STATE="missing"
[[ -x "$BIN_DIR/github-linguist" ]] && LINGUIST_STATE="available"
[[ -x "$BIN_DIR/scc" ]] && SCC_STATE="available"
if [[ "$RUNTIME_KIND" == "none" && ( "$LINGUIST_STATE" == "available" || "$SCC_STATE" == "available" ) ]]; then
    RUNTIME_KIND="development"
fi
write_manifest "$LINGUIST_STATE" "$SCC_STATE"

if [[ "${REQUIRE_LINGUIST_RUNTIME:-0}" == "1" ]]; then
    if [[ "$LINGUIST_STATE" != "available" || "$SCC_STATE" != "available" ]]; then
        echo "error: GitTools runtime incomplete (github-linguist=$LINGUIST_STATE, scc=$SCC_STATE)" >&2
        exit 1
    fi
fi

if [[ "${REQUIRE_RELOCATABLE_LINGUIST_RUNTIME:-0}" == "1" && "$RUNTIME_KIND" != "prebuilt" ]]; then
    echo "error: release packaging requires LINGUIST_RUNTIME_SOURCE with a relocatable GitTools runtime" >&2
    exit 1
fi

echo "GitTools runtime: github-linguist=$LINGUIST_STATE, scc=$SCC_STATE, kind=$RUNTIME_KIND"
