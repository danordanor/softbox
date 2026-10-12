#!/usr/bin/env bash
# Install or update Softbox from the latest release, in one line:
#
#   curl -fsSL https://github.com/danordanor/softbox/releases/latest/download/get.sh | bash
#
# Flags pass through to install.sh, e.g.  ... | bash -s -- --no-hooks
set -euo pipefail
REPO="${SOFTBOX_REPO:-danordanor/softbox}"
URL="https://github.com/$REPO/releases/latest/download/Softbox-mac.zip"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf "\033[1m•\033[0m Downloading Softbox\n"
curl -fsSL "$URL" -o "$tmp/Softbox-mac.zip"
ditto -x -k "$tmp/Softbox-mac.zip" "$tmp"
bash "$tmp/softbox-mac/install.sh" "$@"
