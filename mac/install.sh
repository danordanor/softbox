#!/usr/bin/env bash
# One-shot installer for Softbox on macOS.
#
# It will:
#   1. mint a client certificate from the one the Elgato app already ships
#      (nothing is downloaded; the private key never leaves your machine)
#   2. install the lightd background service (the backend) as a LaunchAgent
#   3. put Softbox.app in the menu bar, starting now and at login
#      (the signed app from a release if it's here, otherwise built from source)
#   4. (optional) wire up Claude Code hooks
#
# Re-running it is safe: it refreshes everything and restarts the service.
set -euo pipefail

# flags: --web (also open the panel in any browser on your network), --no-hooks (skip Claude Code)
WEB=0; HOOKS=1
for a in "$@"; do
  case "$a" in
    --web) WEB=1 ;;
    --no-hooks) HOOKS=0 ;;
  esac
done

HOME_DIR="${LIGHTD_HOME:-$HOME/.softbox}"
APPS_DIR="$HOME/Applications"
SRC="$(cd "$(dirname "$0")" && pwd)"
PY="$(command -v python3)"
PORT="${LIGHTD_PORT:-9124}"
APP="/Applications/Elgato Control Center.app"
PKI="$APP/Contents/Resources/pki_Key_Light_Air_Mk2"
AGENTS="$HOME/Library/LaunchAgents"

bold(){ printf "\033[1m%s\033[0m\n" "$1"; }
say(){ printf "\033[1m•\033[0m %s\n" "$1"; }
warn(){ printf "\033[33m•\033[0m %s\n" "$1"; }
die(){ printf "\033[31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

python3 -c "import ssl" >/dev/null 2>&1 || die "Softbox needs Python 3. Install Apple's Command Line Tools first:  xcode-select --install"
[ -n "$PY" ] || die "python3 not found"

mkdir -p "$HOME_DIR" "$APPS_DIR" "$AGENTS"

# 1. certificate -----------------------------------------------------------
if [ -f "$HOME_DIR/client-chain.crt" ] && [ -f "$HOME_DIR/client.key" ]; then
  say "Client certificate already present"
else
  [ -d "$PKI" ] || die "Elgato Control Center not found. Install it and pair the light first."
  say "Minting a client certificate from the Elgato app"
  ( cd "$HOME_DIR"
    openssl ecparam -name prime256v1 -genkey -noout -out client.key
    openssl req -new -key client.key -subj "/O=Elgato/CN=ElgatoLightsClient" -out client.csr
    printf "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth,serverAuth\n" > ext.cnf
    openssl x509 -req -in client.csr -CA "$PKI/intermediate.crt.pem" -CAkey "$PKI/intermediate.key.pem" \
      -set_serial 01 -days 1825 -sha256 -extfile ext.cnf -out client.crt 2>/dev/null
    cat client.crt "$PKI/intermediate.crt.pem" > client-chain.crt
    rm -f client.csr ext.cnf; chmod 600 client.key )
fi

# 2. backend service -------------------------------------------------------
say "Installing the background service"
cp "$SRC/lightd.py" "$SRC/ui.html" "$SRC/manifest.webmanifest" "$HOME_DIR/"
cp "$SRC"/icon-180.png "$SRC"/icon-192.png "$SRC"/icon-512.png "$HOME_DIR/" 2>/dev/null || true
cp "$SRC/light" "$HOME_DIR/light"; chmod +x "$HOME_DIR/light"
cp "$SRC/uninstall.sh" "$HOME_DIR/uninstall.sh" 2>/dev/null && chmod +x "$HOME_DIR/uninstall.sh" || true
for d in "$HOME/.local/bin" "/opt/homebrew/bin" "/usr/local/bin"; do
  if [ -d "$d" ] && [ -w "$d" ]; then ln -sf "$HOME_DIR/light" "$d/light"; break; fi
done

BPLIST="$AGENTS/dev.softbox.lightd.plist"
sed -e "s|__PYTHON__|$PY|g" -e "s|__DIR__|$HOME_DIR|g" -e "s|__HOME__|$HOME_DIR|g" \
  -e "s|__WEB__|$WEB|g" "$SRC/dev.softbox.lightd.plist.tmpl" > "$BPLIST"
launchctl unload "$BPLIST" 2>/dev/null || true
launchctl load "$BPLIST"
sleep 2
if curl -fsS "http://127.0.0.1:$PORT/api/state" >/dev/null 2>&1; then say "Service is up"
else warn "Service still starting (see $HOME_DIR/lightd.log if the panel stays blank)"; fi

# keep the app's source next to the service: when it changes, the service rebuilds the app
mkdir -p "$HOME_DIR/app"
cp "$SRC"/app/main.swift "$SRC"/app/build-app.sh "$SRC"/app/Info.plist "$SRC"/app/icon.svg "$HOME_DIR/app/"
cp "$SRC"/app/icon-1024.png "$HOME_DIR/app/" 2>/dev/null || true
shasum -a 256 "$HOME_DIR/app/main.swift" | cut -d' ' -f1 > "$HOME_DIR/app/.built"   # built just below

# 3. the menu-bar app ------------------------------------------------------
# quit any running instance so the rebuilt app (and its icon) load clean
osascript -e 'tell application "Softbox" to quit' 2>/dev/null || true
killall Softbox 2>/dev/null || true
install_app() {
  if [ -d "$SRC/Softbox.app" ]; then                 # a release ships the app signed and notarized
    rm -rf "$APPS_DIR/Softbox.app" && ditto "$SRC/Softbox.app" "$APPS_DIR/Softbox.app"
    xattr -dr com.apple.quarantine "$APPS_DIR/Softbox.app" 2>/dev/null || true
  else
    bash "$SRC/app/build-app.sh" "$APPS_DIR"
  fi
}
if install_app; then
  APLIST="$AGENTS/dev.softbox.app.plist"
  cat > "$APLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.softbox.app</string>
  <key>ProgramArguments</key><array>
    <string>$APPS_DIR/Softbox.app/Contents/MacOS/Softbox</string>
  </array>
  <key>EnvironmentVariables</key><dict><key>LIGHTD_PORT</key><string>$PORT</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict></plist>
EOF
  launchctl unload "$APLIST" 2>/dev/null || true
  launchctl load "$APLIST"   # RunAtLoad starts exactly one instance; no separate 'open'
  say "Softbox is in your menu bar (look for the lamp near the clock)"
  APP_OK=1
else
  warn "Could not build the menu-bar app (needs Xcode Command Line Tools: xcode-select --install)."
  APP_OK=0
fi

# 4. Claude Code hooks -----------------------------------------------------
cp "$SRC/hooks_install.py" "$HOME_DIR/"
if [ "$HOOKS" = 1 ]; then
  say "Wiring Claude Code hooks (Ctrl-C within 4s to skip)"; sleep 4 || true
  LIGHTD_PORT="$PORT" python3 "$SRC/hooks_install.py" || warn "Skipped hooks"
fi

echo
bold "Done."
[ "${APP_OK:-0}" = 1 ] && echo "  Click the lamp in the menu bar to open the panel. Right-click it for presets."
if [ "$WEB" = 1 ]; then
  echo "  Web:    http://127.0.0.1:$PORT  (or http://$(scutil --get LocalHostName 2>/dev/null).local:$PORT from another device)"
fi
echo "  CLI:    light on · light b 40 · light focus · light cool"
echo "  Logs:   $HOME_DIR/lightd.log"
echo "  Remove: $HOME_DIR/uninstall.sh"
