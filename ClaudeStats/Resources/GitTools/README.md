GitTools is populated by `scripts/build-linguist-runtime.sh`.

Debug builds may run without the generated tools and will show an unavailable
state in the Git repo inspector. Release builds should set
`LINGUIST_RUNTIME_SOURCE` to a relocatable runtime produced by
`scripts/build-gittools-runtime.sh`.

For local development with the Homebrew Ruby wrapper:

```bash
brew install ruby scc cmake pkg-config icu4c
INSTALL_LINGUIST_RUNTIME=1 bash scripts/build-linguist-runtime.sh
```

The bundled release layout is:

```text
bin/github-linguist
bin/scc
runtime/ruby/...
runtime/lib/*.dylib
gems/...
manifest.json
```

Only `bin/.gitkeep` and this README are tracked. Generated binaries, gems, Ruby
runtime files, and `manifest.json` are ignored.
