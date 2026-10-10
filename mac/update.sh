#!/usr/bin/env bash
# Hot-update the backend without a full reinstall.
#
# Behaviour, the panel, effects and hooks all live in the background service,
# not in the menu-bar app. So this just refreshes those files and restarts the
# service in place. The running app keeps running and shows the new panel the
# next time you open it. The certificate and the app are left untouched.
#
# Run it after pulling new files:   ./update.sh
# (Only a change to the app shell itself — e.g. the menu-bar icon — needs
#  ./install.sh to rebuild Softbox.app.)
set -euo pipefail

HOME_DIR="${LIGHTD_HOME:-$HOME/.softbox}"
SRC="$(cd "$(dirname "$0")" && pwd)"
PORT="${LIGHTD_PORT:-9124}"
LABEL="dev.softbox.lightd"

say(){ printf "\033[1m•\033[0m %s\n" "$1"; }

[ -f "$HOME_DIR/client-chain.crt" ] || { echo "Not installed yet — run ./install.sh first."; exit 1; }

say "Refreshing service files"
cp "$SRC/lightd.py" "$SRC/ui.html" "$SRC/manifest.webmanifest" "$HOME_DIR/"
cp "$SRC"/icon-180.png "$SRC"/icon-192.png "$SRC"/icon-512.png "$HOME_DIR/" 2>/dev/null || true
cp "$SRC/light" "$HOME_DIR/light"; chmod +x "$HOME_DIR/light"

# keep the app's source next to the service: when it changes, the service rebuilds the app
mkdir -p "$HOME_DIR/app"
cp "$SRC"/app/main.swift "$SRC"/app/build-app.sh "$SRC"/app/Info.plist "$SRC"/app/icon.svg "$HOME_DIR/app/"

cp "$SRC/hooks_install.py" "$HOME_DIR/"
if [ "${1:-}" != "--no-hooks" ]; then
  say "Refreshing Claude Code hooks"
  LIGHTD_PORT="$PORT" python3 "$SRC/hooks_install.py" || true
fi

say "Restarting the service in place"
UID_NUM="$(id -u)"
if launchctl kickstart -k "gui/$UID_NUM/$LABEL" 2>/dev/null; then :; else
  # older macOS without kickstart: reload the agent
  P="$HOME/Library/LaunchAgents/$LABEL.plist"
  launchctl unload "$P" 2>/dev/null || true
  launchctl load "$P" 2>/dev/null || true
fi

sleep 2
if curl -fsS "http://127.0.0.1:$PORT/api/state" >/dev/null 2>&1; then
  say "Updated and running. Open the panel to see it."
else
  say "Restarted — give it a few seconds (see $HOME_DIR/lightd.log if blank)."
fi
