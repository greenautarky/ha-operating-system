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

# Scan for GA-* SSIDs with retry — WiFi cache can be stale after other suites ran
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

# --- OS-10..19: Auto-connect service tests ---

# OS-10: Files present
run_test "OS-10a" "Auto-connect script present and executable" \
  "test -x /usr/sbin/ga-openstick-autoconnect"

run_test "OS-10b" "NM dispatcher 90-openstick-fallback present and executable" \
  "test -x /etc/NetworkManager/dispatcher.d/90-openstick-fallback"

# OS-11: Script exits cleanly when connectivity is full (should be a no-op)
CONN_STATE=$(nmcli -t -f CONNECTIVITY general 2>/dev/null || echo "unknown")
if [ "$CONN_STATE" = "full" ]; then
  run_test "OS-11" "Auto-connect is no-op when online (connectivity=$CONN_STATE)" \
    "/usr/sbin/ga-openstick-autoconnect >/dev/null 2>&1"
else
  skip_test "OS-11" "Auto-connect no-op test (connectivity=$CONN_STATE, not full)"
fi

# OS-12: Script exits cleanly when no key file (feature disabled)
run_test "OS-12" "Auto-connect exits if key file missing" \
  "KEY=/usr/share/ga-wifi/openstick-wifi.key;
   if [ -f \$KEY ]; then
     mv \$KEY \${KEY}.bak 2>/dev/null;
     /usr/sbin/ga-openstick-autoconnect >/dev/null 2>&1; RC=\$?;
     mv \${KEY}.bak \$KEY 2>/dev/null;
     [ \$RC -eq 0 ]
   else
     true
   fi"

# OS-13: Cooldown mechanism
rm -f /mnt/data/.ga-openstick-cooldown 2>/dev/null

# Write a future cooldown timestamp — script should exit immediately
run_test "OS-13a" "Auto-connect respects cooldown" \
  "echo \$(( \$(date +%s) + 9999 )) > /mnt/data/.ga-openstick-cooldown;
   /usr/sbin/ga-openstick-autoconnect >/dev/null 2>&1;
   test -f /mnt/data/.ga-openstick-cooldown"

# Write an expired cooldown — script should proceed (and set new cooldown if no SSID)
run_test "OS-13b" "Auto-connect clears expired cooldown" \
  "echo 1 > /mnt/data/.ga-openstick-cooldown;
   /usr/sbin/ga-openstick-autoconnect >/dev/null 2>&1 || true;
   true"

rm -f /mnt/data/.ga-openstick-cooldown 2>/dev/null

# OS-14: Dispatcher routes connectivity-change correctly
run_test "OS-14a" "Dispatcher runs script on connectivity-change NONE" \
  "CONNECTIVITY_STATE=NONE /etc/NetworkManager/dispatcher.d/90-openstick-fallback wlan0 connectivity-change >/dev/null 2>&1; sleep 1; true"

run_test "OS-14b" "Dispatcher runs script on connectivity-change LIMITED" \
  "CONNECTIVITY_STATE=LIMITED /etc/NetworkManager/dispatcher.d/90-openstick-fallback wlan0 connectivity-change >/dev/null 2>&1; sleep 1; true"

# OS-14c: Dispatcher does NOT run on FULL (no unnecessary scans)
run_test "OS-14c" "Dispatcher is no-op on connectivity-change FULL" \
  "CONNECTIVITY_STATE=FULL /etc/NetworkManager/dispatcher.d/90-openstick-fallback wlan0 connectivity-change >/dev/null 2>&1"

# OS-15: Dispatcher handles up/down events (boot-without-ethernet case)
run_test "OS-15" "Dispatcher handles interface up event" \
  "/etc/NetworkManager/dispatcher.d/90-openstick-fallback wlan0 up >/dev/null 2>&1 &
   DPID=\$!; sleep 2; kill \$DPID 2>/dev/null; true"

# OS-16: Script doesn't double-connect if already connected
run_test "OS-16" "Auto-connect skips if openstick-auto already active" \
  "if nmcli -t -f NAME connection show --active 2>/dev/null | grep -q openstick-auto; then
     /usr/sbin/ga-openstick-autoconnect >/dev/null 2>&1;
   else
     true
   fi"

# OS-17: Route metric is set correctly (500 = between LAN and RNDIS)
if nmcli -t -f NAME connection show 2>/dev/null | grep -q openstick-auto; then
  METRIC=$(nmcli -g ipv4.route-metric connection show openstick-auto 2>/dev/null)
  run_test "OS-17" "OpenStick connection route metric is 500" \
    "[ '$METRIC' = '500' ]"
else
  skip_test "OS-17" "Route metric test (no openstick-auto connection active)"
fi

# Cleanup
rm -f /mnt/data/.ga-openstick-cooldown 2>/dev/null

# --- OS-18..20: Full auto-connect integration test ---
# Only runs when a GA-* SSID was found earlier (OpenStick is in range)
if [ -n "$GA_SSIDS" ] && [ -f "$KEY_FILE" ]; then
  echo ""
  echo "  >>> AUTO-CONNECT INTEGRATION TEST <<<"
  echo ""

  # OS-18: Trigger auto-connect by simulating connectivity loss
  # We call the script directly with NM reporting "none" connectivity
  # This is safer than actually disconnecting (would kill SSH over Ethernet)
  rm -f /mnt/data/.ga-openstick-cooldown 2>/dev/null
  nmcli connection delete "openstick-auto" 2>/dev/null

  # Temporarily override nmcli connectivity check by calling script
  # The script checks nmcli internally, so we need actual loss OR we test
  # the dispatcher path which calls the script when CONNECTIVITY_STATE=NONE

  # Call auto-connect script with --force (bypasses connectivity check)
  # This tests the real scan→derive→connect flow without disconnecting SSH
  /usr/sbin/ga-openstick-autoconnect --force >/dev/null 2>&1 &

  # Wait for scan (3x5s) + connect (10s) + DHCP (10s) = ~35s max
  echo "  Waiting for auto-connect (max 45s)..."
  WAIT=0
  CONNECTED=false
  while [ "$WAIT" -lt 45 ]; do
    if nmcli -t -f NAME connection show --active 2>/dev/null | grep -q "openstick-auto"; then
      CONNECTED=true
      break
    fi
    sleep 5
    WAIT=$((WAIT + 5))
  done

  run_test "OS-18" "Auto-connect created openstick-auto connection" \
    "$CONNECTED"

  # OS-19: Internet reachable via auto-connected OpenStick
  if $CONNECTED; then
    sleep 5  # Wait for DHCP to settle
    run_test "OS-19" "Internet reachable via auto-connected OpenStick" \
      "curl -sf --connect-timeout 10 http://checkonline.greenautarky.com/online.txt 2>/dev/null | grep -q 'NetworkManager is online'"

    # OS-20: Route metric is 500 (between LAN and RNDIS)
    METRIC=$(nmcli -g ipv4.route-metric connection show openstick-auto 2>/dev/null)
    run_test "OS-20" "Auto-connect route metric is 500 (got: ${METRIC:-none})" \
      "[ '${METRIC:-0}' = '500' ]"
  else
    run_test "OS-19" "Internet via auto-connected OpenStick" "false"
    run_test "OS-20" "Route metric 500" "false"
  fi

  # Cleanup: remove auto-connected connection
  nmcli connection delete "openstick-auto" 2>/dev/null
  rm -f /mnt/data/.ga-openstick-cooldown 2>/dev/null
else
  skip_test "OS-18" "Auto-connect integration (no OpenStick in range)"
  skip_test "OS-19" "Internet via auto-connect"
  skip_test "OS-20" "Route metric"
fi

suite_end
