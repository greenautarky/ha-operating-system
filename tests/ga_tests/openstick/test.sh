#!/bin/sh
# OpenStick WiFi connectivity test suite - runs ON the device
#
# Tests:
#   OS-01..03: Key file and HMAC derivation
#   OS-04..06: WiFi scanning and OpenStick detection
#   OS-07..09: Connection and internet via OpenStick
#
# Prerequisites:
#   - OpenStick dongle powered and broadcasting GA-XXXX SSID
#   - Shared secret in /usr/share/ga-wifi/openstick-wifi.key
#   - openssl available (for HMAC-SHA256)
#
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "OpenStick WiFi"

KEY_FILE="/usr/share/ga-wifi/openstick-wifi.key"
SSID_PREFIX="GA-"

# --- OS-01..03: Key file and HMAC derivation ---

if [ ! -f "$KEY_FILE" ]; then
  skip_test "OS-01" "Shared secret file exists (not provisioned)"
  skip_test "OS-02" "Shared secret format valid"
  skip_test "OS-03" "HMAC-SHA256 derivation works"
  skip_test "OS-04" "WiFi scan for GA-* SSIDs"
  skip_test "OS-05" "OpenStick SSID detected"
  skip_test "OS-06" "SSID format valid (GA-XXXX)"
  skip_test "OS-07" "PSK derivation matches"
  skip_test "OS-08" "WiFi connection to OpenStick"
  skip_test "OS-09" "Internet via OpenStick"
  suite_end
  exit $?
fi

run_test "OS-01" "Shared secret file exists" \
  "test -f $KEY_FILE"

# Verify format: 64 hex chars, chmod 600
run_test "OS-02a" "Shared secret permissions 600" \
  "[ \"\$(stat -c '%a' $KEY_FILE 2>/dev/null)\" = '600' ]"

run_test "OS-02b" "Shared secret is 64 hex chars (256-bit)" \
  "grep -qE '^[0-9a-f]{64}$' $KEY_FILE 2>/dev/null"

# Test HMAC derivation with a known input
run_test "OS-03" "HMAC-SHA256 derivation produces 16-char PSK" \
  "PSK=\$(echo -n 'GA-0000' | openssl dgst -sha256 -hmac \"\$(cat $KEY_FILE)\" 2>/dev/null | cut -d' ' -f2 | cut -c1-16) && [ \${#PSK} -eq 16 ]"

# --- OS-04..06: WiFi scanning and OpenStick detection ---

# Check if wlan0 exists
if ! ip link show wlan0 >/dev/null 2>&1; then
  skip_test "OS-04" "WiFi interface present (wlan0 missing)"
  skip_test "OS-05" "OpenStick SSID detected"
  skip_test "OS-06" "SSID format valid"
  skip_test "OS-07" "PSK derivation for detected SSID"
  skip_test "OS-08" "WiFi connection to OpenStick"
  skip_test "OS-09" "Internet via OpenStick"
  suite_end
  exit $?
fi

# Scan for GA-* SSIDs (rescan first)
nmcli dev wifi rescan 2>/dev/null
sleep 3

GA_SSIDS=$(nmcli -t -f SSID dev wifi list 2>/dev/null | grep "^${SSID_PREFIX}" | sort -u)

run_test "OS-04" "WiFi scan completed" \
  "nmcli -t -f SSID dev wifi list 2>/dev/null | head -1 | grep -q '.' "

if [ -z "$GA_SSIDS" ]; then
  skip_test "OS-05" "OpenStick SSID detected (no GA-* SSIDs in range)"
  skip_test "OS-06" "SSID format valid"
  skip_test "OS-07" "PSK derivation for detected SSID"
  skip_test "OS-08" "WiFi connection to OpenStick"
  skip_test "OS-09" "Internet via OpenStick"
  suite_end
  exit $?
fi

# Pick first GA-* SSID
TARGET_SSID=$(echo "$GA_SSIDS" | head -1)

run_test "OS-05" "OpenStick SSID detected: $TARGET_SSID" "true"

# Validate SSID format: GA- followed by exactly 4 digits
run_test "OS-06" "SSID format valid (GA-XXXX)" \
  "echo '$TARGET_SSID' | grep -qE '^GA-[0-9]{4}$'"

# --- OS-07..09: Connection test ---

# Derive PSK
SECRET=$(cat "$KEY_FILE" | tr -d '\n')
DERIVED_PSK=$(echo -n "$TARGET_SSID" | openssl dgst -sha256 -hmac "$SECRET" 2>/dev/null | cut -d' ' -f2 | cut -c1-16)

run_test "OS-07" "PSK derived for $TARGET_SSID (${#DERIVED_PSK} chars)" \
  "[ ${#DERIVED_PSK} -eq 16 ]"

# Try to connect (delete any old connection first)
nmcli connection delete "openstick-test" 2>/dev/null

CONNECT_OK=false
if nmcli dev wifi connect "$TARGET_SSID" password "$DERIVED_PSK" \
     name "openstick-test" ifname wlan0 2>/dev/null; then
  CONNECT_OK=true
fi

run_test "OS-08" "WiFi connection to $TARGET_SSID" \
  "$CONNECT_OK"

if $CONNECT_OK; then
  # Wait for DHCP
  sleep 5

  # Check internet connectivity through this connection
  # Use curl since ping may not work on BusyBox
  run_test "OS-09" "Internet reachable via OpenStick" \
    "curl -sf --connect-timeout 10 http://checkonline.greenautarky.com/online.txt 2>/dev/null | grep -q 'NetworkManager is online'"
else
  skip_test "OS-09" "Internet via OpenStick (connection failed)"
fi

# Cleanup: remove test connection, let NM fall back to previous
nmcli connection delete "openstick-test" 2>/dev/null

suite_end
