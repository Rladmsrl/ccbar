#!/usr/bin/env bash
# Build a Debug ClaudeStats.app to the canonical DerivedData path and launch it.
#
# Why not `open -a Claude\ Stats` or the default DerivedData path: this is a
# menu-bar (LSUIElement) app. Multiple registered .app bundles with the same
# bundle id cause Launch Services conflicts and the menu-bar item silently fails
# to appear. Always build to /tmp/Codex-stats-build and launch by full path so
# there is exactly one known bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=/tmp/Codex-stats-build
APP="$DERIVED/Build/Products/Debug/CCBar.app"
APP_PROCESS_PATTERN="CCBar.app/Contents/MacOS/CCBar"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

running_app_pids() {
    pgrep -f "$APP_PROCESS_PATTERN" 2>/dev/null || true
}

wait_until_stopped() {
    local pids
    local attempts="$1"
    for ((i = 0; i < attempts; i++)); do
        pids="$(running_app_pids)"
        if [[ -z "$pids" ]]; then
            return 0
        fi
        sleep 0.15
    done
    return 1
}

stop_running_app() {
    local pids
    pids="$(running_app_pids)"
    if [[ -z "$pids" ]]; then
        return 0
    fi

    echo "==> Stopping existing CCBar process(es): $(echo "$pids" | tr '\n' ' ')"
    kill -TERM $pids 2>/dev/null || true
    if wait_until_stopped 30; then
        return 0
    fi

    pids="$(running_app_pids)"
    echo "==> Existing process ignored SIGTERM; forcing: $(echo "$pids" | tr '\n' ' ')"
    kill -KILL $pids 2>/dev/null || true
    if wait_until_stopped 30; then
        return 0
    fi

    pids="$(running_app_pids)"
    echo "error: unable to stop existing CCBar process(es): $(echo "$pids" | tr '\n' ' ')" >&2
    return 1
}

unregister_bundle_if_present() {
    local bundle="$1"
    if [[ -d "$bundle" ]]; then
        echo "==> Unregistering stale CCBar bundle: $bundle"
        "$LSREGISTER" -u "$bundle" 2>/dev/null || true
    fi
}

cleanup_stale_registrations() {
    unregister_bundle_if_present "/Applications/CCBar.app"
    unregister_bundle_if_present "/tmp/claude-stats-build/Build/Products/Debug/CCBar.app"
    unregister_bundle_if_present "/tmp/Codex-stats-build-tests/Build/Products/Debug/CCBar.app"
}

bash scripts/build-linguist-runtime.sh
bash scripts/generate.sh

# Kill any running instance so the rebuild can replace it.
stop_running_app
cleanup_stale_registrations

xcodebuild \
    -project ClaudeStats.xcodeproj \
    -scheme ClaudeStats \
    -configuration Debug \
    -derivedDataPath "$DERIVED" \
    build

# Refresh Launch Services so the just-built bundle is the registered one.
"$LSREGISTER" -f "$APP" 2>/dev/null || true

open "$APP"
for ((i = 0; i < 20; i++)); do
    if [[ -n "$(running_app_pids)" ]]; then
        break
    fi
    sleep 0.25
done

if [[ -z "$(running_app_pids)" ]]; then
    echo "error: launch did not produce a CCBar process" >&2
    exit 1
fi

for ((i = 0; i < 24; i++)); do
    sleep 0.25
    if [[ -z "$(running_app_pids)" ]]; then
        echo "error: CCBar process exited during startup verification" >&2
        exit 1
    fi
done

echo "Launched $APP"
