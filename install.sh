#!/usr/bin/env bash
# Quit the running Swap, install the freshly built app into /Applications, and relaunch it.
# Build first with ./build.sh.
set -euo pipefail

cd "$(dirname "$0")"

SRC="Swap/build/Release/Swap.app"
DEST="/Applications/Swap.app"

if [ ! -d "$SRC" ]; then
    echo "error: $SRC not found; run ./build.sh first" >&2
    exit 1
fi

# Ask the app to quit, then force it if it doesn't go away.
if pgrep -x Swap >/dev/null; then
    osascript -e 'tell application "Swap" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
        pgrep -x Swap >/dev/null || break
        sleep 0.1
    done
    if pgrep -x Swap >/dev/null; then
        pkill -x Swap || true
        sleep 0.3
    fi
fi

rm -rf "$DEST"
/usr/bin/ditto "$SRC" "$DEST"

open "$DEST"
echo "Installed and launched $DEST"
