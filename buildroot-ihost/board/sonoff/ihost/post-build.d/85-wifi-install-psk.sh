#!/bin/bash
# Inject WiFi PSK into the GreenAutarky-Install connection file.
# PSK is stored in secrets/wifi-install.psk (gitignored).
set -e

TARGET_DIR="$1"
NM_FILE="${TARGET_DIR}/etc/NetworkManager/system-connections/GreenAutarky-Install.nmconnection"
PSK_FILE="/build/secrets/wifi-install.psk"

if [ ! -f "$NM_FILE" ]; then
  echo "wifi-install-psk: no connection template found, skipping"
  exit 0
fi

if [ ! -f "$PSK_FILE" ]; then
  echo "WARNING: $PSK_FILE not found — WiFi fallback will not work"
  echo "         Create secrets/wifi-install.psk with the PSK"
  # Remove the template so NM doesn't try to connect with placeholder
  rm -f "$NM_FILE"
  exit 0
fi

PSK=$(cat "$PSK_FILE" | tr -d '\n')
sed -i "s|__WIFI_INSTALL_PSK__|${PSK}|" "$NM_FILE"
chmod 600 "$NM_FILE"
echo "wifi-install-psk: injected PSK into GreenAutarky-Install connection"
