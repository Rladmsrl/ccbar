#!/usr/bin/env bash
# Run the unit-test bundle against a dedicated DerivedData path.
#
# This script does NOT touch your running CCBar. The test target uses
# CCBar.app as TEST_HOST, but `AppDelegate.applicationDidFinishLaunching`
# skips `env.start()` when launched under xcodebuild test (it checks
# `XCTestConfigurationFilePath`), so the test-host process is a no-op
# shell — no port 23333 bind, no hook install, no floating tab. Your
# dev build keeps running while tests execute.
#
# After tests, the test-build .app is unregistered from Launch Services
# so we don't leave duplicate bundle-id entries (per CLAUDE.md, those
# can make the dev build's menu-bar icon silently disappear).
#
# To rebuild + relaunch the dev build after tests pass, run
# `bash scripts/run-debug.sh` separately.
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=/tmp/Codex-stats-build-tests
TEST_APP="$DERIVED/Build/Products/Debug/CCBar.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

cleanup_test_bundle_registration() {
    if [[ -d "$TEST_APP" ]]; then
        "$LSREGISTER" -u "$TEST_APP" 2>/dev/null || true
    fi
    if [[ -d "/tmp/claude-stats-build/Build/Products/Debug/CCBar.app" ]]; then
        "$LSREGISTER" -u "/tmp/claude-stats-build/Build/Products/Debug/CCBar.app" 2>/dev/null || true
    fi
}

trap cleanup_test_bundle_registration EXIT

bash scripts/build-linguist-runtime.sh
bash scripts/generate.sh
bash scripts/check-slim-provider-residue.sh

xcodebuild \
    -project ClaudeStats.xcodeproj \
    -scheme ClaudeStats \
    -configuration Debug \
    -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS' \
    test
