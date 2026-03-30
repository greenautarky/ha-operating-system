#!/bin/bash
# Inject OpenStick WiFi shared secret into the OS image.
# The secret is used at runtime to derive WiFi passwords from OpenStick SSIDs:
#   PSK = SHA256(SSID + SECRET)[:16]
# Secret is stored in secrets/openstick-wifi.key (gitignored).
set -e

TARGET_DIR="$1"
KEY_FILE="/build/secrets/openstick-wifi.key"
DEST="${TARGET_DIR}/usr/share/ga-wifi/openstick-wifi.key"

if [ ! -f "$KEY_FILE" ]; then
  echo "openstick-wifi-key: no secret found — OpenStick WiFi fallback will not work"
  echo "         Create secrets/openstick-wifi.key with the shared secret"
  exit 0
fi

mkdir -p "$(dirname "$DEST")"
cp "$KEY_FILE" "$DEST"
chmod 600 "$DEST"
echo "openstick-wifi-key: injected shared secret into image"
