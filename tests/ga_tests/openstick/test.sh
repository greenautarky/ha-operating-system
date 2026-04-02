#!/bin/sh
# OpenStick WiFi connectivity test suite - runs ON the device
#
# Tests:
#   OS-01..03: Key file and HMAC derivation
#   OS-04..06: WiFi scanning and OpenStick detection
#   OS-07..09: Connection and internet via OpenStick
#
# All tests FAIL (not skip) if requirements are not met.
# An OpenStick must be powered and broadcasting a GA-XXXX SSID.
#
# Prerequisites:
#   - Shared secret in /usr/share/ga-wifi/openstick-wifi.key (build artifact)
#   - OpenStick dongle powered and broadcasting GA-XXXX SSID
#   - openssl available (for HMAC-SHA256)
#
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "OpenStick WiFi"

KEY_FILE="/usr/share/ga-wifi/openstick-wifi.key"
SSID_PREFIX="GA-"

# --- OS-01..03: Key file and HMAC derivation ---

run_test "OS-01" "Shared secret file exists" \
  "test -f $KEY_FILE"

# Verify format: 64 hex chars, chmod 600
run_test "OS-02a" "Shared secret permissions 600" \
  "[ \"\$(stat -c '%a' $KEY_FILE 2>/dev/null)\" = '600' ]"

run_test "OS-02b" "Shared secret is 64 hex chars (256-bit)" \
  "grep -qE '^[0-9a-f]{64}$' $KEY_FILE 2>/dev/null"

# Test HMAC derivation with a known input
# Try openssl first (available since 16.3.1.2+), fall back to python3 in HA container
derive_psk() {
  local secret="$1" ssid="$2"
  if command -v openssl >/dev/null 2>&1; then
    echo -n "$ssid" | openssl dgst -sha256 -hmac "$secret" 2>/dev/null | cut -d' ' -f2 | cut -c1-16
  else
    docker exec homeassistant python3 -c "import hmac,hashlib,sys; print(hmac.new(sys.argv[1].encode(), sys.argv[2].encode(), hashlib.sha256).hexdigest()[:16])" "$secret" "$ssid" 2>/dev/null
  fi
}
TEST_PSK=$(derive_psk "$(cat $KEY_FILE)" "GA-0000")
run_test "OS-03" "HMAC-SHA256 derivation produces 16-char PSK" \
  "[ ${#TEST_PSK} -eq 16 ]"

# --- OS-04..06: WiFi scanning and OpenStick detection ---

run_test "OS-04a" "WiFi interface wlan0 present" \
  "ip link show wlan0 >/dev/null 2>&1"

# Scan for GA-* SSIDs (multiple rescans — first scan often misses weak signals)
for _scan in 1 2 3; do
  nmcli dev wifi rescan 2>/dev/null
  sleep 5
done

GA_SSIDS=$(nmcli -t -f SSID dev wifi list 2>/dev/null | grep "^${SSID_PREFIX}" | sort -u)

run_test "OS-04" "WiFi scan completed" \
  "nmcli -t -f SSID dev wifi list 2>/dev/null | head -1 | grep -q '.' "

run_test "OS-05" "OpenStick GA-* SSID detected in range" \
  "[ -n '$GA_SSIDS' ]"

if [ -z "$GA_SSIDS" ]; then
  # Still run remaining tests as FAIL (not skip)
  run_test "OS-06" "SSID format valid (GA-XXXX)" "false"
  run_test "OS-07" "PSK derivation for detected SSID" "false"
  run_test "OS-08" "WiFi connection to OpenStick" "false"
  run_test "OS-09" "Internet via OpenStick" "false"
  suite_end
  exit $?
fi

# Pick first GA-* SSID
TARGET_SSID=$(echo "$GA_SSIDS" | head -1)

# OS-05 already passed above

# Validate SSID format: GA- followed by exactly 4 digits
run_test "OS-06" "SSID format valid (GA-XXXX)" \
  "echo '$TARGET_SSID' | grep -qE '^GA-[0-9]{4}$'"

# --- OS-07..09: Connection test ---

# Derive PSK using the same function as OS-03
SECRET=$(cat "$KEY_FILE" | tr -d '\n')
DERIVED_PSK=$(derive_psk "$SECRET" "$TARGET_SSID")

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
  run_test "OS-09" "Internet via OpenStick" "false"
fi

# Cleanup: remove test connection, let NM fall back to previous
nmcli connection delete "openstick-test" 2>/dev/null

# --- OS-10..11: Auto-connect service ---

run_test "OS-10" "Auto-connect script present" \
  "test -x /usr/sbin/ga-openstick-autoconnect"

run_test "OS-11" "NM dispatcher 90-openstick-fallback present" \
  "test -x /etc/NetworkManager/dispatcher.d/90-openstick-fallback"

suite_end
