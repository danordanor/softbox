#!/usr/bin/env bash
# Build Softbox.app from main.swift using swiftc (ships with Xcode / the
# Command Line Tools). Produces a proper .app bundle that runs as a menu-bar
# agent. No Xcode project needed.
#
# Optional, for releases:
#   UNIVERSAL=1                      build for both Apple silicon and Intel
#   VERSION=1.2.0                    stamp the version into Info.plist
#   SIGN_IDENTITY="Developer ID Application: …"   sign with hardened runtime (for notarization)
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

if [ "${UNIVERSAL:-0}" = 1 ]; then
  for arch in arm64 x86_64; do
    swiftc -O "$SRC/main.swift" -o "$MACOS/Softbox-$arch" \
      -framework Cocoa -framework WebKit -target "$arch-apple-macos11.0"
  done
  lipo -create -output "$MACOS/Softbox" "$MACOS/Softbox-arm64" "$MACOS/Softbox-x86_64"
  rm -f "$MACOS/Softbox-arm64" "$MACOS/Softbox-x86_64"
else
  swiftc -O "$SRC/main.swift" -o "$MACOS/Softbox" \
    -framework Cocoa -framework WebKit \
    -target "$(uname -m)-apple-macos11.0"
fi
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

# app icon: the ready-made PNG, or the SVG rasterized as a fallback
if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  tmp="$(mktemp -d)"; png=""
  if [ -f "$SRC/icon-1024.png" ]; then png="$SRC/icon-1024.png"
  elif command -v qlmanage >/dev/null 2>&1 && qlmanage -t -s 1024 -o "$tmp" "$SRC/icon.svg" >/dev/null 2>&1 && [ -f "$tmp/icon.svg.png" ]; then png="$tmp/icon.svg.png"; fi
  if [ -n "$png" ]; then
    set="$tmp/Softbox.iconset"; mkdir -p "$set"
    for sz in 16 32 64 128 256 512; do
      sips -z $sz $sz "$png" --out "$set/icon_${sz}x${sz}.png" >/dev/null 2>&1 || true
      d=$((sz*2)); sips -z $d $d "$png" --out "$set/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1 || true
    done
    iconutil -c icns "$set" -o "$RES/Softbox.icns" 2>/dev/null && \
      /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string Softbox" "$APP/Contents/Info.plist" 2>/dev/null || true
  fi
  rm -rf "$tmp"
fi

if [ -n "${SIGN_IDENTITY:-}" ]; then
  # a release: Developer ID with the hardened runtime and a secure timestamp, ready for notarization
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  # make Gatekeeper happy for a locally built, unsigned app
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
fi

echo "  built $APP"
