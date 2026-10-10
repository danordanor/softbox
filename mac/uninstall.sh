#!/usr/bin/env bash
# Remove Softbox: quit the app and service, remove hooks, delete files.
# Keeps the client certificate unless you pass --all.
set -euo pipefail
HOME_DIR="${LIGHTD_HOME:-$HOME/.softbox}"
AGENTS="$HOME/Library/LaunchAgents"

echo "• Stopping the menu-bar app"
launchctl unload "$AGENTS/dev.softbox.app.plist" 2>/dev/null || true
rm -f "$AGENTS/dev.softbox.app.plist"
osascript -e 'tell application "Softbox" to quit' 2>/dev/null || true
rm -rf "$HOME/Applications/Softbox.app"

echo "• Stopping the service"
launchctl unload "$AGENTS/dev.softbox.lightd.plist" 2>/dev/null || true
rm -f "$AGENTS/dev.softbox.lightd.plist"

echo "• Removing Claude Code hooks"
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && [ -f "$HOME_DIR/hooks_install.py" ]; then
  python3 "$HOME_DIR/hooks_install.py" --remove || true
fi

echo "• Removing CLI links"
for d in "$HOME/.local/bin" "/opt/homebrew/bin" "/usr/local/bin"; do
  [ -L "$d/light" ] && rm -f "$d/light" || true
done

echo "• Removing files"
rm -f "$HOME_DIR"/{lightd.py,ui.html,light,config.json,lightd.log,uninstall.sh,manifest.webmanifest,hooks_install.py,icon-180.png,icon-192.png,icon-512.png}
rm -rf "$HOME_DIR/app"
if [ "${1:-}" = "--all" ]; then
  rm -f "$HOME_DIR"/{client.key,client.crt,client-chain.crt}
  echo "  removed certificate too"
fi
echo "Done."
