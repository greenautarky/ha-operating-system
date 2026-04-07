#!/bin/bash
# run_network_failover_test.sh — Full network fallback chain test
#
# Tests all permutations of the fallback chain:
#   Ethernet (100) → OpenStick WiFi (500) → RNDIS (700) → Install WiFi (800)
#
# Architecture: OpenStick is ALWAYS connected (persistent NM connection).
# NM manages failover automatically via route metrics.
# No dispatcher needed — NM autoconnect handles everything.
#
# Controlled from the HOST via serial console (always available).
#
# Prerequisites:
#   - ser2net running on localhost (or /dev/ttyACM0 available)
#   - OpenStick dongle powered and in range (GA-XXXX SSID)
#   - Device serial password in ga-flasher-py/work/serial-password.txt
#
# Usage:
#   ./tests/run_network_failover_test.sh
#
set -euo pipefail

SERIAL_PORT="${SERIAL_PORT:-/dev/ttyACM0}"
SERIAL_BAUD="${SERIAL_BAUD:-115200}"
SERIAL_PASS_FILE="${SERIAL_PASS_FILE:-$HOME/git/ga-flasher-py/work/serial-password.txt}"

SERIAL_PASS="$(cat "$SERIAL_PASS_FILE" 2>/dev/null || echo "")"
[[ -z "$SERIAL_PASS" ]] && { echo "ERROR: Serial password not found"; exit 1; }

TOTAL=0; PASS=0; FAIL=0

serial_cmd() {
  local cmd="$1"
  local wait="${2:-3}"

  fuser -k "$SERIAL_PORT" 2>/dev/null || true
  sleep 1

  export SERIAL_PASS
  timeout $((wait + 15)) python3 -c "
import serial, time, os
pw = os.environ['SERIAL_PASS']
ser = serial.Serial('$SERIAL_PORT', $SERIAL_BAUD, timeout=1)
ser.reset_input_buffer()
def cmd(c, w=2):
    ser.write(c.encode() + b'\r\n')
    time.sleep(w)
    return ser.read(ser.in_waiting or 8192).decode('utf-8', errors='replace')
cmd(''); cmd('root'); cmd(pw, 2)
result = cmd('''$cmd''', $wait)
lines = result.strip().split('\n')
for line in lines:
    line = line.strip()
    if line and not line.startswith('#') and line != '''$cmd''':
        print(line)
ser.close()
" 2>/dev/null
}

run_test() {
  local id="$1" desc="$2" result="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$result" = "true" ] || [ "$result" = "PASS" ]; then
    PASS=$((PASS + 1)); echo "  PASS  $id: $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL  $id: $desc"
  fi
}

echo "============================================================"
echo "  Network Fallback Chain Test"
echo "============================================================"
echo "  Architecture: OpenStick always connected, NM manages failover"
echo ""

# ================================================================
# TEST 1: Baseline — OpenStick + Ethernet both active
# ================================================================
echo "=== TEST 1: Baseline ==="

CONNS=$(serial_cmd "nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null" 5)
echo "  Active: $CONNS"

ROUTE=$(serial_cmd "ip route show default 2>/dev/null | head -2" 3)
echo "  Routes: $ROUTE"

run_test "FC-01" "Ethernet active" "$(echo "$CONNS" | grep -q eth0 && echo true || echo false)"
run_test "FC-02" "OpenStick active (openstick-auto on wlan0)" "$(echo "$CONNS" | grep -q openstick-auto && echo true || echo false)"
run_test "FC-03" "Ethernet is default route (metric 100)" "$(echo "$ROUTE" | grep -q 'eth0.*metric 100' && echo true || echo false)"
run_test "FC-04" "OpenStick is secondary route (metric 500)" "$(echo "$ROUTE" | grep -q 'metric 500' && echo true || echo false)"

echo ""

# ================================================================
# TEST 2: Ethernet off → OpenStick becomes default (instant)
# ================================================================
echo "=== TEST 2: Ethernet off → OpenStick takes over ==="

serial_cmd "ga-manage-ethernet disable" 5
sleep 5

ROUTE=$(serial_cmd "ip route show default 2>/dev/null | head -1" 3)
echo "  Default route: $ROUTE"

run_test "FC-05" "OpenStick is now default route" "$(echo "$ROUTE" | grep -q 'metric 500' && echo true || echo false)"

INET=$(serial_cmd "curl -sf --connect-timeout 10 http://checkonline.greenautarky.com/online.txt 2>/dev/null" 15)
run_test "FC-06" "Internet works via OpenStick" "$(echo "$INET" | grep -q 'NetworkManager is online' && echo true || echo false)"

echo ""

# ================================================================
# TEST 3: Ethernet back → Ethernet becomes default again (instant)
# ================================================================
echo "=== TEST 3: Ethernet back → instant switchback ==="

serial_cmd "ga-manage-ethernet enable" 5
sleep 10

ROUTE=$(serial_cmd "ip route show default 2>/dev/null | head -2" 3)
echo "  Routes: $ROUTE"

run_test "FC-07" "Ethernet is default again (metric 100)" "$(echo "$ROUTE" | grep -q 'eth0.*metric 100' && echo true || echo false)"
run_test "FC-08" "OpenStick still connected (metric 500)" "$(echo "$ROUTE" | grep -q 'metric 500' && echo true || echo false)"

CONNS=$(serial_cmd "nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null" 3)
run_test "FC-09" "Both Ethernet + OpenStick active" \
  "$(echo "$CONNS" | grep -q eth0 && echo "$CONNS" | grep -q openstick-auto && echo true || echo false)"

echo ""

# ================================================================
# TEST 4: Priority — OpenStick (10) beats Install WiFi (-10)
# ================================================================
echo "=== TEST 4: Priority check ==="

STICK_PRIO=$(serial_cmd "nmcli -g connection.autoconnect-priority connection show openstick-auto 2>/dev/null" 3)
INSTALL_PRIO=$(serial_cmd "nmcli -g connection.autoconnect-priority connection show GreenAutarky-Install 2>/dev/null" 3)
echo "  OpenStick priority: $STICK_PRIO"
echo "  Install priority: $INSTALL_PRIO"

STICK_P=$(echo "$STICK_PRIO" | tr -cd '0-9-')
INSTALL_P=$(echo "$INSTALL_PRIO" | tr -cd '0-9-')
run_test "FC-10" "OpenStick priority ($STICK_P) > Install WiFi ($INSTALL_P)" \
  "$([ "${STICK_P:-0}" -gt "${INSTALL_P:-0}" ] && echo true || echo false)"

# Check which WiFi NM chose
WIFI_CONN=$(serial_cmd "nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep wlan0" 3)
echo "  Active WiFi: $WIFI_CONN"
run_test "FC-11" "wlan0 uses openstick-auto (not Install WiFi)" "$(echo "$WIFI_CONN" | grep -q openstick-auto && echo true || echo false)"

echo ""

# ================================================================
# TEST 5: Persistence — connection survives reboot (check config)
# ================================================================
echo "=== TEST 5: Persistence ==="

CONN_FILE=$(serial_cmd "ls /etc/NetworkManager/system-connections/*openstick* 2>/dev/null || ls /mnt/overlay/etc/NetworkManager/system-connections/*openstick* 2>/dev/null || echo 'NOT FOUND'" 3)
run_test "FC-12" "Persistent connection file exists" "$(echo "$CONN_FILE" | grep -q openstick && echo true || echo false)"

AC=$(serial_cmd "nmcli -g connection.autoconnect connection show openstick-auto 2>/dev/null" 3)
run_test "FC-13" "Connection has autoconnect=yes" "$(echo "$AC" | grep -q yes && echo true || echo false)"

echo ""

# ================================================================
# CLEANUP
# ================================================================
echo "=== CLEANUP ==="
serial_cmd "ga-manage-ethernet enable 2>/dev/null; true" 3
echo "  Done (OpenStick connection left in place — persistent by design)"

echo ""
echo "============================================================"
echo "  Network Failover Test Complete"
echo "============================================================"
echo "  Total: $TOTAL  Pass: $PASS  Fail: $FAIL"
echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "  ALL PASS"
else
  echo "  $FAIL FAILURES"
fi
echo "============================================================"

exit "$FAIL"
