#!/usr/bin/env bash
# Build Softbox/Softbox.p12 — the client identity the app uses to authenticate
# to the light. Run this once on your Mac before building in Xcode.
#
# It reuses the certificate the Mac app already minted (~/.softbox), or mints a
# fresh one from the Elgato Control Center app if that's not there. The private
# key never leaves your machine; it only gets bundled into your own build.
set -euo pipefail
cd "$(dirname "$0")"

ELG="$HOME/.softbox"
PKI="/Applications/Elgato Control Center.app/Contents/Resources/pki_Key_Light_Air_Mk2"
OUT="Softbox/Softbox.p12"
PASS="keylight"

if [ -f "$ELG/client.key" ] && [ -f "$ELG/client-chain.crt" ]; then
  KEY="$ELG/client.key"; CHAIN="$ELG/client-chain.crt"
  echo "• Using the certificate already in ~/.softbox"
else
  [ -d "$PKI" ] || { echo "Elgato Control Center not found, and no cert in ~/.softbox. Install the app and pair the light first." >&2; exit 1; }
  echo "• Minting a client certificate from the Elgato app"
  mkdir -p "$ELG"; cd "$ELG"
  openssl ecparam -name prime256v1 -genkey -noout -out client.key
  openssl req -new -key client.key -subj "/O=Elgato/CN=ElgatoLightsClient" -out client.csr
  printf "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth,serverAuth\n" > ext.cnf
  openssl x509 -req -in client.csr -CA "$PKI/intermediate.crt.pem" -CAkey "$PKI/intermediate.key.pem" \
    -set_serial 01 -days 1825 -sha256 -extfile ext.cnf -out client.crt 2>/dev/null
  cat client.crt "$PKI/intermediate.crt.pem" > client-chain.crt
  rm -f client.csr ext.cnf; chmod 600 client.key
  cd - >/dev/null
  KEY="$ELG/client.key"; CHAIN="$ELG/client-chain.crt"
fi

echo "• Packing it into $OUT"
openssl pkcs12 -export -inkey "$KEY" -in "$CHAIN" -name Softbox -passout "pass:$PASS" -out "$OUT"
echo "Done. Now open Softbox.xcodeproj in Xcode and run it on your iPhone."
