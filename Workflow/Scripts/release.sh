#!/bin/bash

# Build what a release publishes: a notarized disk image of the Mac app and an
# unsigned .ipa of the iOS app (for sideloading: whoever installs it signs it).
#
# Usage:
#   bash Workflow/Scripts/release.sh            # both
#   bash Workflow/Scripts/release.sh mac        # catussh-<version>.dmg
#   bash Workflow/Scripts/release.sh ios        # catussh-<version>.ipa
#
# Products are written to $DERIVED_DATA_PATH/Release.
#
# The Mac app is signed with the keychain's Developer ID Application
# certificate, with the hardened runtime and a secure timestamp, then the disk
# image is sent to Apple's notary service and the ticket stapled to it.
#
# Notary credentials, the first that is set:
#   NOTARY_KEYCHAIN_PROFILE              a profile saved with
#                                        `xcrun notarytool store-credentials`
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID
#                                        an App Store Connect API key (.p8)
#   NOTARY_APPLE_ID, NOTARY_PASSWORD     an Apple ID and app-specific password
# With none, the disk image is signed but not notarized, and the script says so;
# REQUIRE_NOTARIZATION=1 makes that an error.
#
# With a Developer ID provisioning profile for the app (see build-macos.sh;
# MAC_PROVISIONING_PROFILE names one), the Mac app can sync with iCloud: the
# profile grants the key-value store and the keychain access group sync keeps
# its key in, which the signing below carries over from the build.
#
# Other environment overrides:
#   CODE_SIGN_IDENTITY    Certificate for the Mac app; "-" signs ad hoc, which
#                         is only good for trying the script
#   DERIVED_DATA_PATH     Build products directory (default: ./DerivedData)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/DerivedData}"
OUTPUT_DIR="$DERIVED_DATA_PATH/Release"
TARGET="${1:-all}"

case "$TARGET" in
    all|mac|ios) ;;
    *) printf 'Usage: bash %s [all|mac|ios]\n' "$0" >&2; exit 2 ;;
esac

step() { printf '\n==> %s\n' "$*"; }
version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1"; }

mkdir -p "$OUTPUT_DIR"

# MARK: - Mac

notarize() {
    local image="$1" credentials=()
    if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
        credentials=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
    elif [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
        credentials=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    elif [[ -n "${NOTARY_APPLE_ID:-}" ]]; then
        credentials=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$TEAM")
    else
        if [[ "${REQUIRE_NOTARIZATION:-}" == 1 ]]; then
            printf 'No notary credentials; see the top of %s.\n' "$0" >&2
            exit 1
        fi
        printf 'No notary credentials: %s is signed but NOT notarized.\n' "$(basename "$image")"
        return
    fi

    step "Mac: notarizing (this takes a few minutes)"
    local result
    result="$(mktemp)"
    xcrun notarytool submit "$image" "${credentials[@]}" --wait --output-format json > "$result" || true
    local status id
    status="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$result" 2>/dev/null || true)"
    id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$result" 2>/dev/null || true)"
    if [[ "$status" != Accepted ]]; then
        printf 'Notarization did not succeed (status: %s).\n' "${status:-none}" >&2
        cat "$result" >&2
        [[ -n "$id" ]] && xcrun notarytool log "$id" "${credentials[@]}" >&2 || true
        exit 1
    fi
    rm -f "$result"
    xcrun stapler staple "$image"
    xcrun stapler validate "$image"
}

release_mac() {
    local identity="${CODE_SIGN_IDENTITY:-}"
    if [[ -z "$identity" ]]; then
        identity="$(security find-identity -v -p codesigning \
            | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    fi
    if [[ -z "$identity" ]]; then
        printf 'No Developer ID Application certificate in the keychain.\n' >&2
        exit 1
    fi
    TEAM=""
    if [[ "$identity" != "-" ]]; then
        TEAM="$(security find-certificate -c "$identity" -p \
            | openssl x509 -noout -subject -nameopt multiline \
            | sed -n 's/^ *organizationalUnitName *= *//p' | head -1)"
    fi

    step "Mac: building ($identity)"
    CODE_SIGN_IDENTITY="$identity" DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
        bash "$ROOT_DIR/Workflow/Scripts/build-macos.sh" Release > "$OUTPUT_DIR/mac-build.log" 2>&1 || {
        grep -E 'error:' "$OUTPUT_DIR/mac-build.log" | sort -u | head -20 >&2
        printf 'Mac build failed; the full log is %s\n' "$OUTPUT_DIR/mac-build.log" >&2
        exit 1
    }

    local built="$DERIVED_DATA_PATH/Build/Products/Release/catussh.app"
    local version stage app
    version="$(version_of "$built/Contents/Info.plist")"
    stage="$OUTPUT_DIR/mac"
    app="$stage/catussh.app"
    rm -rf "$stage"
    mkdir -p "$stage"
    ditto "$built" "$app"

    # The build's signature lets a debugger attach, which the notary service
    # refuses, and carries no secure timestamp. Signed again without the one
    # and with the other: nested code first, then the app.
    step "Mac: signing for distribution"
    local entitlements="$OUTPUT_DIR/mac-entitlements.plist"
    /usr/bin/codesign -d --entitlements - --xml "$built" 2>/dev/null > "$entitlements"
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$entitlements" 2>/dev/null || true
    local timestamp=(--timestamp)
    [[ "$identity" == "-" ]] && timestamp=(--timestamp=none)
    find "$app/Contents" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.appex' -o -path '*/PlugIns/*.bundle' \) -print0 \
        | while IFS= read -r -d '' nested; do
            /usr/bin/codesign --force --sign "$identity" --options runtime "${timestamp[@]}" "$nested"
        done
    /usr/bin/codesign --force --sign "$identity" --options runtime "${timestamp[@]}" \
        --entitlements "$entitlements" "$app"
    /usr/bin/codesign --verify --deep --strict --all-architectures "$app"

    step "Mac: making the disk image"
    local image="$OUTPUT_DIR/catussh-$version.dmg"
    rm -f "$image"
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname "catussh $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$image" >/dev/null
    if [[ "$identity" == "-" ]]; then
        printf 'Signed ad hoc: %s will not open on another Mac.\n' "$(basename "$image")"
    else
        /usr/bin/codesign --force --sign "$identity" --timestamp "$image"
        notarize "$image"
    fi
    rm -rf "$stage" "$entitlements"
    printf '%s\n' "$image"
}

# MARK: - iOS

release_ios() {
    step "iOS: building"
    local ios_data="$DERIVED_DATA_PATH/iOS"
    if ! xcodebuild \
        -workspace "$ROOT_DIR/App.xcworkspace" \
        -scheme mCatussh \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$ios_data" \
        CODE_SIGNING_ALLOWED=NO \
        build > "$OUTPUT_DIR/ios-build.log" 2>&1; then
        grep -E 'error:' "$OUTPUT_DIR/ios-build.log" | sort -u | head -20 >&2
        printf 'iOS build failed; the full log is %s\n' "$OUTPUT_DIR/ios-build.log" >&2
        exit 1
    fi

    step "iOS: packaging"
    local built="$ios_data/Build/Products/Release-iphoneos/mCatussh.app"
    local version stage archive
    version="$(version_of "$built/Info.plist")"
    stage="$OUTPUT_DIR/ios"
    archive="$OUTPUT_DIR/catussh-$version.ipa"
    rm -rf "$stage" "$archive"
    mkdir -p "$stage/Payload"
    ditto "$built" "$stage/Payload/catussh.app"
    (cd "$stage" && /usr/bin/zip -qry "$archive" Payload)
    rm -rf "$stage"
    printf '%s\n' "$archive"
}

[[ "$TARGET" == all || "$TARGET" == mac ]] && release_mac
[[ "$TARGET" == all || "$TARGET" == ios ]] && release_ios

step "Done"
ls -lh "$OUTPUT_DIR"/catussh-* | awk '{print "  " $5 "  " $9}'
