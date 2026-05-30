#!/usr/bin/env bash
# Build a Release CCBar.app and package it for distribution into ./dist/.
#
# Two modes, selected automatically by whether SIGN_IDENTITY is set:
#
#   • Signed mode (SIGN_IDENTITY set): codesign with a Developer ID Application
#     identity + hardened runtime, package a DMG, notarize it with notarytool,
#     and staple the ticket.  Output: dist/CCBar-<version>.dmg
#
#   • Unsigned mode (SIGN_IDENTITY unset): ad-hoc sign, package both a DMG and a
#     .zip.  Gatekeeper will warn on first launch (right-click ▸ Open).
#     Output: dist/CCBar-<version>.dmg and dist/CCBar-<version>.zip
#
# Usage: bash scripts/release-build.sh [version]
#   [version]  version label for the artifact file names; defaults to the
#              MARKETING_VERSION currently in project.yml.
#
# Environment (signed mode):
#   SIGN_IDENTITY              codesign identity, e.g. "Developer ID Application: Foo (TEAMID)"
#   APPLE_TEAM_ID              10-char Apple Developer Team ID
#   APPLE_ID + APP_PASSWORD    Apple ID + app-specific password for notarytool
#   NOTARY_KEYCHAIN_PROFILE    (alternative to APPLE_ID/APP_PASSWORD) a stored notarytool profile
#
# Environment (all release builds):
#   LINGUIST_RUNTIME_SOURCE    relocatable GitTools runtime produced by
#                              scripts/build-gittools-runtime.sh
#
# The finished artifacts are written to ./dist/.
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=/tmp/claude-stats-release
DIST="$PWD/dist"
SIGNED_ENTITLEMENTS="$DIST/signed-entitlements.plist"

VERSION="${1:-$(grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')}"
[[ -n "$VERSION" ]] || { echo "error: could not determine version" >&2; exit 1; }
DMG="$DIST/CCBar-$VERSION.dmg"
ZIP="$DIST/CCBar-$VERSION.zip"

SIGNED=0
[[ -n "${SIGN_IDENTITY:-}" ]] && SIGNED=1

echo "==> Building CCBar $VERSION (Release, $([[ $SIGNED -eq 1 ]] && echo "signed + notarized" || echo "unsigned"))"
REQUIRE_LINGUIST_RUNTIME="${REQUIRE_LINGUIST_RUNTIME:-1}" \
REQUIRE_RELOCATABLE_LINGUIST_RUNTIME="${REQUIRE_RELOCATABLE_LINGUIST_RUNTIME:-1}" \
    bash scripts/build-linguist-runtime.sh
bash scripts/generate.sh

rm -rf "$DERIVED" "$DIST"
mkdir -p "$DIST"

CONFIGURATION=Release
RELEASE_ARCHS="${RELEASE_ARCHS:-$(uname -m)}"
XCODE_BUILD_ARGS=(ARCHS="$RELEASE_ARCHS")
if [[ $SIGNED -eq 1 ]]; then
    [[ -n "${APPLE_TEAM_ID:-}" ]] || {
        echo "error: signed builds require APPLE_TEAM_ID" >&2
        exit 1
    }
    echo "==> Signing with: $SIGN_IDENTITY (hardened runtime)"
    CONFIGURATION=ReleaseSigned
else
    XCODE_BUILD_ARGS+=(CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Automatic ENABLE_HARDENED_RUNTIME=NO)
fi

PRODUCTS="$DERIVED/Build/Products/$CONFIGURATION"
APP="$PRODUCTS/CCBar.app"

codesign_release() {
    local attempt=1
    local max_attempts=3
    local delay=5
    local status=0

    while true; do
        if codesign "$@"; then
            return 0
        fi

        status=$?
        if [[ "$attempt" -ge "$max_attempts" ]]; then
            return "$status"
        fi

        echo "warning: codesign failed on attempt $attempt/$max_attempts; retrying in ${delay}s" >&2
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
}

xcodebuild \
    -project ClaudeStats.xcodeproj \
    -scheme ClaudeStats \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED" \
    "${XCODE_BUILD_ARGS[@]}" \
    build

[[ -d "$APP" ]] || { echo "error: build did not produce $APP" >&2; exit 1; }

GITTOOLS_DIR="$APP/Contents/Resources/GitTools"
bash scripts/gittools/prune-debug-symbols.sh "$GITTOOLS_DIR"

echo "==> Verifying bundled GitTools runtime"
bash scripts/verify-gittools-runtime.sh "$GITTOOLS_DIR"

if [[ $SIGNED -eq 1 ]]; then
    # Capture the entitlements xcodebuild resolved for the app so the final
    # manual re-sign below preserves them. Strip Xcode's auto-injected
    # `get-task-allow` entitlement, which Apple's notary rejects.
    echo "==> Capturing resolved app entitlements"
    codesign -d --entitlements :- "$APP" > "$SIGNED_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$SIGNED_ENTITLEMENTS" 2>/dev/null || true

    # xcodebuild signs the main app and the immediate framework bundle, but does
    # NOT recurse into Sparkle.framework to re-sign its XPC services, helper app,
    # or helper executable — they keep Sparkle's own distribution signature,
    # which Apple's notary rejects ("not signed with a valid Developer ID
    # certificate" + "signature does not include a secure timestamp"). Re-sign
    # each nested binary bottom-up, then the framework, then the main app. The
    # final re-sign of the main app, with our entitlements file passed
    # explicitly, also strips Xcode's auto-injected `get-task-allow` entitlement
    # (also rejected by notary).
    echo "==> Deep re-signing Sparkle.framework contents + main app"
    SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
    if [[ -d "$SPARKLE_FW" ]]; then
        for item in \
            "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" \
            "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" \
            "$SPARKLE_FW/Versions/B/Updater.app" \
            "$SPARKLE_FW/Versions/B/Autoupdate"; do
            [[ -e "$item" ]] && codesign_release --force --options runtime --timestamp \
                --sign "$SIGN_IDENTITY" "$item"
        done
        codesign_release --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$SPARKLE_FW"
    fi
    if [[ -d "$GITTOOLS_DIR" ]]; then
        while IFS= read -r -d '' item; do
            if file "$item" | grep -q 'Mach-O'; then
                codesign_release --force --options runtime --timestamp \
                    --sign "$SIGN_IDENTITY" "$item"
            fi
        done < <(find "$GITTOOLS_DIR" -type d -name '*.dSYM' -prune -o -type f -print0)
    fi
    codesign_release --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" \
        --entitlements "$SIGNED_ENTITLEMENTS" \
        "$APP"
fi

make_dmg() {
    local stage; stage="$(mktemp -d)"
    local rw_dmg="$DIST/.CCBar-$VERSION-rw.dmg"
    local mount_dir; mount_dir="$(mktemp -d)"
    local attached=0

    cleanup_dmg_stage() {
        if [[ $attached -eq 1 ]]; then
            hdiutil detach "$mount_dir" -quiet || hdiutil detach "$mount_dir" -force || true
        fi
        rm -f "$rw_dmg"
        rmdir "$mount_dir" 2>/dev/null || true
        rm -rf "$stage"
    }
    trap cleanup_dmg_stage RETURN

    cp -R "$APP" "$stage/"
    ln -s /Applications "$stage/Applications"
    mkdir -p "$stage/.background"
    swift scripts/render-dmg-background.swift "$stage/.background/dmg-background.png"

    hdiutil create -volname "CCBar" -srcfolder "$stage" -ov -fs HFS+ -format UDRW "$rw_dmg"
    hdiutil attach "$rw_dmg" -mountpoint "$mount_dir" -nobrowse -noverify -noautoopen
    attached=1

    osascript <<APPLESCRIPT
tell application "Finder"
    set dmgFolder to folder (POSIX file "$mount_dir" as alias)
    set backgroundImage to POSIX file "$mount_dir/.background/dmg-background.png" as alias

    tell dmgFolder
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {220, 120, 1140, 682}

        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 16
        set background picture of viewOptions to backgroundImage

        set position of item "CCBar.app" to {235, 255}
        set position of item "Applications" to {665, 255}
        select item "CCBar.app"

        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

    sync
    hdiutil detach "$mount_dir" -quiet || hdiutil detach "$mount_dir" -force
    attached=0
    hdiutil convert "$rw_dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" -ov
    trap - RETURN
    cleanup_dmg_stage
}

assert_no_get_task_allow_entitlements() {
    local root="$1"
    local found=0

    while IFS= read -r -d '' item; do
        if ! file "$item" | grep -q 'Mach-O'; then
            continue
        fi

        local entitlements
        entitlements="$(mktemp "$DIST/entitlements-check.XXXXXX")"
        if codesign -d --entitlements :- "$item" > "$entitlements" 2>/dev/null; then
            local get_task_allow
            get_task_allow="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$entitlements" 2>/dev/null || true)"
            if [[ "$get_task_allow" == "true" ]]; then
                echo "error: release executable has com.apple.security.get-task-allow=true: $item" >&2
                found=1
            fi
        fi
        rm -f "$entitlements"
    done < <(find "$root" -type d -name '*.dSYM' -prune -o -type f -print0)

    if [[ $found -ne 0 ]]; then
        exit 1
    fi
}

if [[ $SIGNED -eq 0 ]]; then
    echo "==> Packaging DMG + zip (unsigned)"
    make_dmg
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "==> Done (unsigned): $DMG, $ZIP"
    ls -la "$DIST"
    exit 0
fi

echo "==> Verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "==> Checking release entitlements"
assert_no_get_task_allow_entitlements "$APP"

echo "==> Packaging DMG"
make_dmg

echo "==> Signing DMG"
codesign_release --sign "$SIGN_IDENTITY" --timestamp "$DMG"

echo "==> Submitting to Apple notary service (this can take a few minutes)"
NOTARY_ARGS=()
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APP_PASSWORD" --team-id "$APPLE_TEAM_ID")
else
    echo "error: notarization needs NOTARY_KEYCHAIN_PROFILE or APPLE_ID + APP_PASSWORD + APPLE_TEAM_ID" >&2
    exit 1
fi

# notarytool returns 0 even when status=Invalid (submission "completed",
# content was rejected), so parse the status ourselves and fail loudly with
# the actual log instead of letting stapler fail with a misleading error.
SUBMIT_LOG="$DIST/notarytool-submit.log"
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait | tee "$SUBMIT_LOG"
SUBMIT_STATUS="$(awk -F': *' '/^[[:space:]]*status:/ {print $2; exit}' "$SUBMIT_LOG" | tr -d '[:space:]')"
if [[ "$SUBMIT_STATUS" != "Accepted" ]]; then
    SUBMIT_ID="$(awk -F': *' '/^[[:space:]]*id:/ {print $2; exit}' "$SUBMIT_LOG" | tr -d '[:space:]')"
    echo "==> Notarization failed (status: $SUBMIT_STATUS) — fetching log" >&2
    [[ -n "$SUBMIT_ID" ]] && xcrun notarytool log "$SUBMIT_ID" "${NOTARY_ARGS[@]}" >&2 || true
    exit 1
fi

echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG" || true

echo "==> Done (signed + notarized): $DMG"
ls -la "$DIST"
