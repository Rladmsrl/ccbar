#!/usr/bin/env bash
# Build a relocatable GitTools runtime for release packaging.
#
# Output layout:
#   <output>/bin/github-linguist
#   <output>/bin/scc
#   <output>/runtime/ruby/...
#   <output>/runtime/lib/*.dylib
#   <output>/gems/...
#   <output>/manifest.json
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-}"
[[ -n "$OUT" ]] || { echo "usage: $0 <output-dir>" >&2; exit 2; }

RUBY_VERSION="${RUBY_VERSION:-3.4.6}"
LINGUIST_VERSION="${LINGUIST_VERSION:-9.5.0}"
SCC_VERSION="${SCC_VERSION:-3.5.0}"
ARCH="$(uname -m)"

case "$OUT" in
    /|"" )
        echo "error: unsafe output directory: $OUT" >&2
        exit 1
        ;;
esac

OUT="$(mkdir -p "$(dirname "$OUT")" && cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/runtime" "$OUT/runtime/lib" "$OUT/gems"

require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: missing required tool '$1'" >&2
        exit 1
    }
}

brew_prefix() {
    brew --prefix "$1" 2>/dev/null || true
}

require_tool brew
require_tool ruby-build
require_tool go
require_tool otool
require_tool install_name_tool

OPENSSL_PREFIX="$(brew_prefix openssl@3)"
READLINE_PREFIX="$(brew_prefix readline)"
LIBYAML_PREFIX="$(brew_prefix libyaml)"
GMP_PREFIX="$(brew_prefix gmp)"
ICU_PREFIX="$(brew_prefix icu4c)"

RUBY_CONFIGURE_FLAGS=(--disable-install-doc --enable-load-relative)
[[ -n "$OPENSSL_PREFIX" ]] && RUBY_CONFIGURE_FLAGS+=(--with-openssl-dir="$OPENSSL_PREFIX")
[[ -n "$READLINE_PREFIX" ]] && RUBY_CONFIGURE_FLAGS+=(--with-readline-dir="$READLINE_PREFIX")
[[ -n "$LIBYAML_PREFIX" ]] && RUBY_CONFIGURE_FLAGS+=(--with-libyaml-dir="$LIBYAML_PREFIX")
[[ -n "$GMP_PREFIX" ]] && RUBY_CONFIGURE_FLAGS+=(--with-gmp-dir="$GMP_PREFIX")

export RUBY_CONFIGURE_OPTS="${RUBY_CONFIGURE_OPTS:-} ${RUBY_CONFIGURE_FLAGS[*]}"
if [[ -n "$ICU_PREFIX" ]]; then
    export PKG_CONFIG_PATH="$ICU_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi

RUBY_PREFIX="$OUT/runtime/ruby"
echo "==> Building Ruby $RUBY_VERSION for $ARCH"
ruby-build "$RUBY_VERSION" "$RUBY_PREFIX"

RUBY="$RUBY_PREFIX/bin/ruby"
GEM="$RUBY_PREFIX/bin/gem"
BUNDLE="$RUBY_PREFIX/bin/bundle"

if [[ ! -x "$BUNDLE" ]]; then
    "$GEM" install bundler --no-document
fi

BUNDLE_WORK="$OUT/runtime/bundle"
mkdir -p "$BUNDLE_WORK"
cp scripts/gittools/Gemfile "$BUNDLE_WORK/Gemfile"
cp scripts/gittools/Gemfile.lock "$BUNDLE_WORK/Gemfile.lock"

echo "==> Installing github-linguist $LINGUIST_VERSION"
(
    cd "$BUNDLE_WORK"
    export GEM_HOME="$OUT/gems"
    export GEM_PATH="$OUT/gems"
    export PATH="$OUT/gems/bin:$RUBY_PREFIX/bin:$PATH"
    "$BUNDLE" config set --local path "$OUT/gems"
    "$BUNDLE" config set --local frozen true
    "$BUNDLE" config set --local without "development test"
    [[ -n "$ICU_PREFIX" ]] && "$BUNDLE" config set --local build.charlock_holmes "--with-icu-dir=$ICU_PREFIX"
    "$BUNDLE" install --jobs "${BUNDLE_JOBS:-4}" --retry 3
)
rm -rf "$BUNDLE_WORK/.bundle"

echo "==> Building scc $SCC_VERSION"
GOBIN="$OUT/bin" go install "github.com/boyter/scc/v3@v$SCC_VERSION"
[[ -x "$OUT/bin/scc" ]] || { echo "error: scc was not built into $OUT/bin" >&2; exit 1; }

cat > "$OUT/bin/github-linguist" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
export GEM_HOME="$ROOT/gems"
export GEM_PATH="$ROOT/gems"
export BUNDLE_GEMFILE="$ROOT/runtime/bundle/Gemfile"
export BUNDLE_PATH="$ROOT/gems"
export BUNDLE_APP_CONFIG="$ROOT/runtime/bundle/.bundle"
export BUNDLE_WITHOUT="development:test"
export PATH="$ROOT/runtime/ruby/bin:/usr/bin:/bin:/usr/sbin:/sbin"
exec "$ROOT/runtime/ruby/bin/ruby" "$ROOT/runtime/ruby/bin/bundle" exec github-linguist "$@"
SH
chmod +x "$OUT/bin/github-linguist"

echo "==> Rewriting Mach-O dependencies"
bash scripts/gittools/prune-debug-symbols.sh "$OUT"
bash scripts/gittools/fix-mach-o-install-names.sh "$OUT"
bash scripts/gittools/prune-debug-symbols.sh "$OUT"

cat > "$OUT/manifest.json" <<JSON
{
  "runtimeKind": "prebuilt",
  "architecture": "$ARCH",
  "rubyVersion": "$RUBY_VERSION",
  "githubLinguist": "bundled",
  "linguistVersion": "$LINGUIST_VERSION",
  "scc": "bundled",
  "sccVersion": "$SCC_VERSION",
  "builtAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "verified": false
}
JSON

echo "==> Verifying GitTools runtime"
bash scripts/verify-gittools-runtime.sh "$OUT"

/usr/bin/ruby -rjson -e '
  path = ARGV.fetch(0)
  data = JSON.parse(File.read(path))
  data["verified"] = true
  File.write(path, JSON.pretty_generate(data) + "\n")
' "$OUT/manifest.json"

echo "==> GitTools runtime ready: $OUT"
