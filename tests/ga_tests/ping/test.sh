#!/bin/sh
# Ping monitoring test suite - runs ON the device
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Ping Monitoring"


# Tier-1 (error logs) and tier-2 (metrics) shippers are consent-gated by design:
# telegraf has ConditionPathExists=/mnt/data/.ga-consent-metrics, fluent-bit
# (tier-1) has ConditionPathExists=/mnt/data/.ga-consent-error_logs. Without the
# marker the unit is inactive on purpose and its env file does not exist. Tests
# that assert on them must SKIP with the reason, not FAIL — on a fresh device
# without consent they were 12 structural reds (2026-09-02, K31 rc19).
_consent_metrics()    { [ -f /mnt/data/.ga-consent-metrics ]; }
_consent_error_logs() { [ -f /mnt/data/.ga-consent-error_logs ]; }
if _consent_metrics; then
run_test "PING-01" "GATEWAY_IP auto-detected (not unknown)" \
  "grep 'GATEWAY_IP=' /mnt/data/telegraf/env 2>/dev/null | grep -qv 'unknown'"

run_test_show "PING-01b" "Gateway IP value" \
  "grep GATEWAY_IP /mnt/data/telegraf/env 2>/dev/null"
else
  skip_test "PING-01" "GATEWAY_IP in telegraf env (tier-2 metrics consent not given — env does not exist)"
  skip_test "PING-01b" "Gateway IP value (same)"
fi

run_test "PING-02" "Telegraf ping plugin loaded (no errors)" \
  "! journalctl -u telegraf --no-pager -q 2>/dev/null | grep -qi 'error.*ping'"

run_test "PING-06" "Native ping method configured" \
  "grep -q 'method.*=.*\"native\"' /etc/telegraf/telegraf.conf 2>/dev/null"

# ping binary may be broken on minimal HAOS (BusyBox stub)
if ping -c 1 -W 2 127.0.0.1 >/dev/null 2>&1; then
  if _consent_metrics; then
  run_test "PING-03" "Gateway is pingable" \
    "GW=\$(grep GATEWAY_IP /mnt/data/telegraf/env 2>/dev/null | cut -d= -f2); [ -n \"\$GW\" ] && [ \"\$GW\" != 'unknown' ] && ping -c 1 -W 3 \$GW >/dev/null 2>&1"
  else
    GW=$(ip route 2>/dev/null | awk \'/^default/ {print $3; exit}\')
    run_test "PING-03" "Gateway is pingable (from ip route: ${GW:-none})" \
      "[ -n \"$GW\" ] && ping -c 1 -W 3 $GW >/dev/null 2>&1"
  fi
  run_test "PING-04" "1.1.1.1 is pingable" \
    "ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1"
  # Use GA connectivity endpoint (works over VPN, not just direct internet)
  run_test "PING-05" "Internet reachable (checkonline.greenautarky.com)" \
    "curl -sf --connect-timeout 10 http://checkonline.greenautarky.com/online.txt 2>/dev/null | grep -q 'NetworkManager is online'"
else
  # ping broken — verify connectivity via ARP + Telegraf ping metrics
  # Without tier-2 consent there is no telegraf env — take the gateway from the
  # routing table, which is what the device actually uses.
  GW=$(grep GATEWAY_IP /mnt/data/telegraf/env 2>/dev/null | cut -d= -f2)
  [ -n "$GW" ] && [ "$GW" != unknown ] || GW=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')
  run_test "PING-03" "Gateway reachable (ARP table: ${GW:-none})" \
    "grep -q '${GW:-NO_GW}' /proc/net/arp 2>/dev/null"
  if _consent_metrics; then
    run_test "PING-04" "Telegraf ping plugin reporting data" \
      "journalctl -u telegraf --no-pager -q --since '3 hours ago' 2>/dev/null | grep -qi 'ping'"
  else
    skip_test "PING-04" "Telegraf ping plugin reporting data (tier-2 metrics consent not given)"
  fi
  # Use GA connectivity endpoint (works over VPN, not just direct internet)
  run_test "PING-05" "Internet reachable (checkonline.greenautarky.com)" \
    "curl -sf --connect-timeout 10 http://checkonline.greenautarky.com/online.txt 2>/dev/null | grep -q 'NetworkManager is online'"
fi

skip_test "PING-07" "Data reaches InfluxDB" "no InfluxDB CLI on device"

suite_end
