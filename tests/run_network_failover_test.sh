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
# TESTS 6 + 7 (Odoo #2201 D8, 2026-11-28) — the failure the link-based tests
# above cannot see: eth0 LINK UP, INTERNET DEAD (K181), and its green twin.
#   6  red case   egress over eth0 is dropped ON THE DEVICE (iptables OUTPUT and
#                 FORWARD -o eth0, so host processes AND containers lose it; the
#                 link and the DHCP lease stay up). Must hold:
#                   FC-20 the per-path probe marks eth0 not clean, the dongle path clean
#                   FC-21 the default route leaves eth0 within FAILOVER_BUDGET_S
#                   FC-22 an AUTHENTICATED outcome over the new path: the device's
#                         own report reaches the STAGING fleet-manager after the
#                         switch (last_seen newer than the injection) — never
#                         `systemctl is-active`
#                   FC-23 internet back on eth0 -> the route returns to eth0
#                         (after the hysteresis), and FC-22's outcome holds again
#                 Until D1/D3 (route switch by metric) lands, FC-21/FC-23 are
#                 EXPECTED RED: that red is this test's proof that it can fail.
#   7  green case two healthy paths for GREEN_WINDOW_S: no switch at all (the
#                 default route stays on eth0, the ladder logs no switch) — a
#                 failover that ping-pongs on a healthy site is a defect too.
# Needs for FC-22/23: FM_URL (staging, e.g. http://<ga-tools>:8091), FM_TOKEN_FILE
# (staging operator token), DEVICE_ID. Without them FC-22/23 are SKIP "not
# covered" — never PASS. The drop rules are removed on EVERY exit (trap).
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
# TEST 6 + 7: eth0 link up, internet dead (red) / two healthy paths (green)
# ================================================================
FAILOVER_BUDGET_S="${FAILOVER_BUDGET_S:-180}"
RETURN_BUDGET_S="${RETURN_BUDGET_S:-600}"
GREEN_WINDOW_S="${GREEN_WINDOW_S:-1200}"
SKIP=0
skip_test() { TOTAL=$((TOTAL + 1)); SKIP=$((SKIP + 1)); echo "  SKIP  $1: $2 (not covered: $3)"; }
DROP_ON='iptables -I OUTPUT 1 -o eth0 -j DROP -m comment --comment ga-failover-test; iptables -I FORWARD 1 -o eth0 -j DROP -m comment --comment ga-failover-test'
DROP_OFF='while iptables -D OUTPUT -o eth0 -j DROP -m comment --comment ga-failover-test 2>/dev/null; do :; done; while iptables -D FORWARD -o eth0 -j DROP -m comment --comment ga-failover-test 2>/dev/null; do :; done; echo DROP-OFF'
trap 'serial_cmd "$DROP_OFF" 5 >/dev/null 2>&1 || true' EXIT

default_dev() { serial_cmd "ip -4 route show default 2>/dev/null | head -1" 3 | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1; }
# force one fresh per-path probe + ladder tick (drop the cadence state first)
probe_now() { serial_cmd "rm -rf /run/ga-uplink-ladder.state.paths.d; systemctl start ga-uplink-ladder.service; cat /mnt/data/supervisor/share/ga-uplink.json" 40; }
path_verdict() { printf '%s' "$1" | tr '{' '\n' | grep "\"iface\":\"$2\"" | sed -n 's/.*"verdict":"\([a-z_]*\)".*/\1/p' | head -1; }
fm_last_seen() {   # epoch of the device's last authenticated report in the staging fm, empty if unknown
  [ -n "${FM_URL:-}" ] && [ -r "${FM_TOKEN_FILE:-}" ] && [ -n "${DEVICE_ID:-}" ] || return 0
  curl -fsS --max-time 15 -H "Authorization: Bearer $(cat "$FM_TOKEN_FILE")" "${FM_URL%/}/api/devices/$DEVICE_ID" 2>/dev/null \
    | python3 -c 'import sys,json,datetime as d
r=json.load(sys.stdin); v=r.get("last_seen") or r.get("last_seen_at") or ""
print(int(d.datetime.fromisoformat(v.replace("Z","+00:00")).timestamp()) if v else "")' 2>/dev/null
}
outcome_after() {  # outcome_after EPOCH NAME -> PASS / FAIL / SKIP line for an authenticated report newer than EPOCH
  local since="$1" id="$2" what="$3" t0 ls
  if [ -z "${FM_URL:-}" ] || [ ! -r "${FM_TOKEN_FILE:-}" ] || [ -z "${DEVICE_ID:-}" ]; then skip_test "$id" "$what" "FM_URL / FM_TOKEN_FILE / DEVICE_ID not set"; return; fi
  t0=$(date +%s); ls=""
  while [ $(( $(date +%s) - t0 )) -lt 300 ]; do
    ls="$(fm_last_seen)"; [ -n "$ls" ] && [ "$ls" -gt "$since" ] && break; ls=""; sleep 15
  done
  run_test "$id" "$what (fm last_seen ${ls:-none} > $since)" "$([ -n "$ls" ] && echo true || echo false)"
}

echo "=== TEST 6: eth0 link up, internet dead (Odoo #2201 D8, red case) ==="
[ "$(default_dev)" = eth0 ] || echo "  WARNING: default route is not on eth0 before the test ($(default_dev)) - FC-21/23 prove less"
T_INJECT=$(date +%s)
serial_cmd "$DROP_ON; echo DROP-ON" 5 | grep -q DROP-ON || echo "  WARNING: could not confirm the drop rules"
CARRIER=$(serial_cmd "cat /sys/class/net/eth0/carrier" 3 | tr -cd '01')
echo "  eth0 carrier during the test: ${CARRIER:-?} (must stay 1: link up, internet dead)"
J=$(probe_now)
run_test "FC-20" "per-path probe: eth0 not clean ($(path_verdict "$J" eth0)), dongle path wlan0 clean ($(path_verdict "$J" wlan0))" \
  "$([ "$(path_verdict "$J" eth0)" != clean ] && [ -n "$(path_verdict "$J" eth0)" ] && [ "$(path_verdict "$J" wlan0)" = clean ] && echo true || echo false)"
dev=""; waited=0
while [ "$waited" -lt "$FAILOVER_BUDGET_S" ]; do dev="$(default_dev)"; [ -n "$dev" ] && [ "$dev" != eth0 ] && break; sleep 15; waited=$((waited + 15)); done
run_test "FC-21" "default route left eth0 within ${FAILOVER_BUDGET_S}s (now: ${dev:-none}, after ${waited}s) [expected RED until D1/D3]" \
  "$([ -n "$dev" ] && [ "$dev" != eth0 ] && echo true || echo false)"
outcome_after "$T_INJECT" "FC-22" "authenticated device report reaches the fm over the new path"
T_BACK=$(date +%s)
serial_cmd "$DROP_OFF" 5 >/dev/null
dev=""; waited=0
while [ "$waited" -lt "$RETURN_BUDGET_S" ]; do dev="$(default_dev)"; [ "$dev" = eth0 ] && break; sleep 15; waited=$((waited + 15)); done
run_test "FC-23" "internet back on eth0: default route returned to eth0 within ${RETURN_BUDGET_S}s (after ${waited}s) [expected RED until D1/D3]" \
  "$([ "$dev" = eth0 ] && echo true || echo false)"
outcome_after "$T_BACK" "FC-23b" "authenticated device report after the return"
echo ""

echo "=== TEST 7: two healthy paths, NO switch for ${GREEN_WINDOW_S}s (green case) ==="
T7=$(date +%s); flips=0; prev="$(default_dev)"
while [ $(( $(date +%s) - T7 )) -lt "$GREEN_WINDOW_S" ]; do
  cur="$(default_dev)"; [ "$cur" = "$prev" ] || { flips=$((flips + 1)); echo "  route moved: $prev -> $cur"; prev="$cur"; }
  sleep 60
done
SW=$(serial_cmd "journalctl -t ga-uplink-ladder --since=@$T7 --no-pager -q 2>/dev/null | grep -c 'switched\|parked' " 10 | tr -cd '0-9')
run_test "FC-24" "two healthy paths: default route stayed on eth0, ${flips} move(s), ladder switch/park lines: ${SW:-?}" \
  "$([ "$prev" = eth0 ] && [ "$flips" = 0 ] && [ "${SW:-x}" = 0 ] && echo true || echo false)"
J=$(probe_now)
run_test "FC-25" "two healthy paths: both probe clean (eth0 $(path_verdict "$J" eth0), wlan0 $(path_verdict "$J" wlan0))" \
  "$([ "$(path_verdict "$J" eth0)" = clean ] && [ "$(path_verdict "$J" wlan0)" = clean ] && echo true || echo false)"
outcome_after "$T7" "FC-26" "authenticated device report during the healthy window"
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
echo "  Total: $TOTAL  Pass: $PASS  Fail: $FAIL  Skip: ${SKIP:-0}"
echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "  ALL PASS"
else
  echo "  $FAIL FAILURES"
fi
echo "============================================================"

exit "$FAIL"
