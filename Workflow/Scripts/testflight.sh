#!/bin/bash

# Archive the iOS app and upload it to App Store Connect for TestFlight.
#
# Usage:
#   bash Workflow/Scripts/testflight.sh            # archive and upload
#   bash Workflow/Scripts/testflight.sh export     # archive and export the .ipa only
#
# The app is signed by Xcode's automatic signing for team LT98S43NKA: the
# archive with Apple Development, the upload with Apple Distribution and an
# App Store profile, which Xcode makes and keeps up to date itself. The app
# record (bundle id me.mizorewww.rayon) must already exist in App Store
# Connect; Xcode does not make it.
#
# App Store Connect is reached as the Apple ID signed in to Xcode (Settings ›
# Accounts), or with an App Store Connect API key when these are all set:
#   ASC_KEY_PATH       the .p8 file
#   ASC_KEY_ID         its key id
#   ASC_ISSUER_ID      the issuer id from Users and Access › Integrations
#
# Other environment overrides:
#   BUILD_NUMBER       CFBundleVersion (default: the time, which only grows)
#   DEVELOPMENT_TEAM   Team (default: LT98S43NKA)
#   DERIVED_DATA_PATH  Build products directory (default: ./DerivedData)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/DerivedData}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-LT98S43NKA}"
# Each upload needs a build number above the last one of its version.
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d.%H%M)}"
ACTION="${1:-upload}"

case "$ACTION" in
    upload|export) ;;
    *) printf 'Usage: bash %s [upload|export]\n' "$0" >&2; exit 2 ;;
esac

step() { printf '\n==> %s\n' "$*"; }

OUTPUT_DIR="$DERIVED_DATA_PATH/TestFlight"
ARCHIVE="$OUTPUT_DIR/catussh.xcarchive"
mkdir -p "$OUTPUT_DIR"

auth=()
if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
    auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

step "Archiving build $BUILD_NUMBER"
rm -rf "$ARCHIVE"
if ! xcodebuild \
    -workspace "$ROOT_DIR/App.xcworkspace" \
    -scheme mCatussh \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$OUTPUT_DIR/DerivedData" \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    archive > "$OUTPUT_DIR/archive.log" 2>&1; then
    grep -E 'error:' "$OUTPUT_DIR/archive.log" | sort -u | head -20 >&2
    printf 'Archive failed; the full log is %s\n' "$OUTPUT_DIR/archive.log" >&2
    exit 1
fi

destination=upload
[[ "$ACTION" == export ]] && destination=export
options="$OUTPUT_DIR/ExportOptions.plist"
cat > "$options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>$destination</string>
    <key>teamID</key>
    <string>$DEVELOPMENT_TEAM</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
EOF

if [[ "$destination" == upload ]]; then
    step "Uploading to App Store Connect"
else
    step "Exporting for App Store Connect"
fi
if ! xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$options" \
    -exportPath "$OUTPUT_DIR/Export" \
    -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} \
    > "$OUTPUT_DIR/export.log" 2>&1; then
    grep -E 'error:|Error' "$OUTPUT_DIR/export.log" | sort -u | head -20 >&2
    printf 'Export failed; the full log is %s\n' "$OUTPUT_DIR/export.log" >&2
    exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$ARCHIVE/Info.plist")"
if [[ "$destination" == upload ]]; then
    step "Uploaded $version ($BUILD_NUMBER)"
    printf 'It shows in App Store Connect › TestFlight once Apple has processed it (usually a few minutes).\n'
else
    step "Exported $version ($BUILD_NUMBER): $OUTPUT_DIR/Export"
fi
