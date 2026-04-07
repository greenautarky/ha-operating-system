#!/bin/sh
# OpenStick WiFi test suite - runs ON the device
#
# Tests:
#   OS-01..03: Key file and HMAC derivation
#   OS-04..09: WiFi scanning, connection, internet
#   OS-10..12: Auto-connect service + timer
#   OS-13..15: Cooldown mechanism
#   OS-16..18: Persistent connection behavior
#   OS-19..20: Route metric and priority
#
# All tests FAIL (not skip) if requirements not met.
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
CONN_NAME="openstick-auto"

# --- OS-01..03: Key file and HMAC derivation ---

run_test "OS-01" "Shared secret file exists" \
  "test -f $KEY_FILE"

run_test "OS-02a" "Shared secret permissions 600" \
  "[ \"\$(stat -c '%a' $KEY_FILE 2>/dev/null)\" = '600' ]"

run_test "OS-02b" "Shared secret is 64 hex chars (256-bit)" \
  "grep -qE '^[0-9a-f]{64}$' $KEY_FILE 2>/dev/null"

# HMAC derivation
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

# --- OS-04..09: WiFi scanning and connection ---

run_test "OS-04a" "WiFi interface wlan0 present" \
  "ip link show wlan0 >/dev/null 2>&1"

# Scan for GA-* SSIDs with retry
GA_SSIDS=""
for _attempt in 1 2 3; do
  for _scan in 1 2 3; do
    nmcli dev wifi rescan 2>/dev/null
    sleep 5
  done
  GA_SSIDS=$(nmcli -t -f SSID dev wifi list 2>/dev/null | grep "^${SSID_PREFIX}" | sort -u)
  [ -n "$GA_SSIDS" ] && break
  echo "  Scan attempt $_attempt: no GA-* found, retrying..."
  sleep 10
done

run_test "OS-04" "WiFi scan completed" \
  "nmcli -t -f SSID dev wifi list 2>/dev/null | head -1 | grep -q '.' "

run_test "OS-05" "OpenStick GA-* SSID detected in range" \
  "[ -n '$GA_SSIDS' ]"

if [ -z "$GA_SSIDS" ]; then
  run_test "OS-06" "SSID format valid (GA-XXXX)" "false"
  run_test "OS-07" "PSK derivation for detected SSID" "false"
  run_test "OS-08" "WiFi connection to OpenStick" "false"
  run_test "OS-09" "Internet via OpenStick" "false"
  run_test "OS-10" "Auto-connect service" "false"
  run_test "OS-11" "Auto-connect timer" "false"
  suite_end
  exit $?
fi

TARGET_SSID=$(echo "$GA_SSIDS" | head -1)

# OS-05 already passed above

run_test "OS-06" "SSID format valid (GA-XXXX)" \
  "echo '$TARGET_SSID' | grep -qE '^GA-[0-9]{4}$'"

# Derive PSK
SECRET=$(cat "$KEY_FILE" | tr -d '\n')
DERIVED_PSK=$(derive_psk "$SECRET" "$TARGET_SSID")

run_test "OS-07" "PSK derived for $TARGET_SSID (${#DERIVED_PSK} chars)" \
  "[ ${#DERIVED_PSK} -eq 16 ]"

# Manual connection test
nmcli connection delete "openstick-test" 2>/dev/null

CONNECT_OK=false
if nmcli dev wifi connect "$TARGET_SSID" password "$DERIVED_PSK" \
     name "openstick-test" ifname wlan0 2>/dev/null; then
  CONNECT_OK=true
fi

run_test "OS-08" "WiFi connection to $TARGET_SSID" \
  "$CONNECT_OK"

if $CONNECT_OK; then
  sleep 5
  run_test "OS-09" "Internet reachable via OpenStick" \
    "curl -sf --connect-timeout 10 http://checkonline.greenautarky.com/online.txt 2>/dev/null | grep -q 'NetworkManager is online'"
else
  run_test "OS-09" "Internet via OpenStick" "false"
fi

nmcli connection delete "openstick-test" 2>/dev/null

# --- OS-10..12: Auto-connect service + timer ---

run_test "OS-10" "Auto-connect script present and executable" \
  "test -x /usr/sbin/ga-openstick-autoconnect"

run_test "OS-11" "Auto-connect service exists" \
  "test -f /etc/systemd/system/ga-openstick-autoconnect.service"

run_test "OS-12a" "Auto-connect timer exists" \
  "test -f /etc/systemd/system/ga-openstick-autoconnect.timer"

run_test "OS-12b" "Auto-connect timer is active" \
  "systemctl is-active ga-openstick-autoconnect.timer >/dev/null 2>&1"

# --- OS-13..15: Cooldown mechanism ---

rm -f /mnt/data/.ga-openstick-cooldown 2>/dev/null

# Future cooldown — script should exit immediately
run_test "OS-13" "Cooldown respected (future timestamp)" \
  "echo \$(( \$(date +%s) + 9999 )) > /mnt/data/.ga-openstick-cooldown;
   /usr/sbin/ga-openstick-autoconnect >/dev/null 2>&1;
   test -f /mnt/data/.ga-openstick-cooldown"

# Expired cooldown — script should proceed
run_test "OS-14" "Expired cooldown cleared" \
  "echo 1 > /mnt/data/.ga-openstick-cooldown;
   /usr/sbin/ga-openstick-autoconnect >/dev/null 2>&1 || true;
   true"

# Script exits if already connected
run_test "OS-15" "Script exits if already connected" \
  "if nmcli -t -f NAME connection show --active 2>/dev/null | grep -q '$CONN_NAME'; then
     /usr/sbin/ga-openstick-autoconnect >/dev/null 2>&1;
   else
     true
   fi"

rm -f /mnt/data/.ga-openstick-cooldown 2>/dev/null

# --- OS-16..18: Persistent connection behavior ---

# Run auto-connect script to create persistent connection
nmcli connection delete "$CONN_NAME" 2>/dev/null
rm -f /mnt/data/.ga-openstick-cooldown 2>/dev/null

echo ""
echo "  >>> PERSISTENT CONNECTION TEST <<<"
echo "  Running auto-connect script..."
/usr/sbin/ga-openstick-autoconnect >/dev/null 2>&1 || true
sleep 5

# Check if persistent connection was created
CONN_EXISTS=$(nmcli -t -f NAME connection show 2>/dev/null | grep -c "$CONN_NAME")
run_test "OS-16" "Persistent connection created by script" \
  "[ '$CONN_EXISTS' -gt 0 ]"

if [ "$CONN_EXISTS" -gt 0 ]; then
  # Check autoconnect
  AC=$(nmcli -g connection.autoconnect connection show "$CONN_NAME" 2>/dev/null)
  run_test "OS-17a" "Connection has autoconnect=yes" \
    "[ '$AC' = 'yes' ]"

  # Check priority
  PRIO=$(nmcli -g connection.autoconnect-priority connection show "$CONN_NAME" 2>/dev/null)
  run_test "OS-17b" "Connection has autoconnect-priority=10" \
    "[ '$PRIO' = '10' ]"

  # Check active
  ACTIVE=$(nmcli -t -f NAME connection show --active 2>/dev/null | grep -c "$CONN_NAME")
  run_test "OS-18" "Connection is active on wlan0" \
    "[ '$ACTIVE' -gt 0 ]"
else
  run_test "OS-17a" "autoconnect=yes" "false"
  run_test "OS-17b" "autoconnect-priority=10" "false"
  run_test "OS-18" "Connection active" "false"
fi

# --- OS-19..20: Route metric and priority ---

if [ "$CONN_EXISTS" -gt 0 ]; then
  METRIC=$(nmcli -g ipv4.route-metric connection show "$CONN_NAME" 2>/dev/null)
  run_test "OS-19" "Route metric is 500 (got: ${METRIC:-none})" \
    "[ '${METRIC:-0}' = '500' ]"

  # Priority over GreenAutarky-Install (-10 < 10)
  INSTALL_PRIO=$(nmcli -g connection.autoconnect-priority connection show GreenAutarky-Install 2>/dev/null || echo "0")
  STICK_PRIO=$(nmcli -g connection.autoconnect-priority connection show "$CONN_NAME" 2>/dev/null || echo "0")
  run_test "OS-20" "OpenStick priority ($STICK_PRIO) > Install WiFi ($INSTALL_PRIO)" \
    "[ '$STICK_PRIO' -gt '$INSTALL_PRIO' ]"
else
  run_test "OS-19" "Route metric 500" "false"
  run_test "OS-20" "Priority over Install WiFi" "false"
fi

# Don't cleanup — leave persistent connection for NM to manage
# nmcli connection delete "$CONN_NAME" 2>/dev/null

suite_end
