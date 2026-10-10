#!/usr/bin/env bash
# Build Softbox.app from main.swift using swiftc (ships with Xcode / the
# Command Line Tools). Produces a proper .app bundle that runs as a menu-bar
# agent. No Xcode project needed.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HOME/Applications}"
APP="$OUT/Softbox.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

command -v swiftc >/dev/null || {
  echo "swiftc not found. Install the Command Line Tools with:  xcode-select --install" >&2
  exit 1
}

echo "• Building Softbox.app"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"

swiftc -O "$SRC/main.swift" -o "$MACOS/Softbox" \
  -framework Cocoa -framework WebKit \
  -target "$(uname -m)-apple-macos11.0"

# optional app icon, if tools are available to rasterize the SVG
if command -v qlmanage >/dev/null 2>&1 && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  if qlmanage -t -s 1024 -o "$tmp" "$SRC/icon.svg" >/dev/null 2>&1 && [ -f "$tmp/icon.svg.png" ]; then
    set="$tmp/Softbox.iconset"; mkdir -p "$set"
    for sz in 16 32 64 128 256 512; do
      sips -z $sz $sz "$tmp/icon.svg.png" --out "$set/icon_${sz}x${sz}.png" >/dev/null 2>&1 || true
      d=$((sz*2)); sips -z $d $d "$tmp/icon.svg.png" --out "$set/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1 || true
    done
    iconutil -c icns "$set" -o "$RES/Softbox.icns" 2>/dev/null && \
      /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string Softbox" "$APP/Contents/Info.plist" 2>/dev/null || true
  fi
  rm -rf "$tmp"
fi

# make Gatekeeper happy for a locally built, unsigned app
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "  built $APP"
