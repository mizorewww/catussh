#!/bin/bash

# Build catussh in Release configuration and install it to /Applications.
#
# Usage:
#   bash Workflow/Scripts/install-macos.sh
#
# Environment overrides:
#   INSTALL_DIR        Target directory (default: /Applications)
#   DERIVED_DATA_PATH  Build products directory (default: ./DerivedData)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_NAME="catussh.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/DerivedData}"

# 1. Build Release (Mac Catalyst, universal arm64/x86_64, signed, codesign-verified).
bash "$ROOT_DIR/Workflow/Scripts/build-macos.sh" Release

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release-maccatalyst/$APP_NAME"
DEST="$INSTALL_DIR/$APP_NAME"

if [[ ! -d "$APP_PATH" ]]; then
    printf 'error: build product not found at %s\n' "$APP_PATH" >&2
    exit 1
fi

# 2. A catussh still running from the old copy would keep running it from
#    the Trash, and a later `open` could bring that copy back. Ask it to quit
#    (it asks about open terminals, as for any quit) and wait for it.
running() { pgrep -f "^$DEST/Contents/MacOS/catussh\$" >/dev/null 2>&1; }
if running; then
    printf 'Quitting the running catussh…\n'
    osascript -e 'tell application id "me.mizorewww.rayon" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do running || break; sleep 1; done
    if running; then
        printf 'error: catussh is still running (answer its quit question, or quit it), then run this again.\n' >&2
        exit 1
    fi
fi

# 3. Replace any existing installation. Prefer the Trash when possible.
if [[ -d "$DEST" ]]; then
    printf 'Replacing existing %s\n' "$DEST"
    if command -v trash >/dev/null 2>&1; then
        trash "$DEST"
    else
        rm -rf "$DEST"
    fi
fi

# 4. Install. ditto preserves bundle metadata better than cp -R.
ditto "$APP_PATH" "$DEST"

# Locally built apps carry no quarantine attribute, but clear it in case
# the derived-data path ever does (e.g. after transferring an archive).
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

printf '\nInstalled: %s\n' "$DEST"
printf 'Launch with: open %s\n' "$DEST"
