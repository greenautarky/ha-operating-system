#!/bin/sh
# Ping monitoring test suite - runs ON the device
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Ping Monitoring"

run_test "PING-01" "GATEWAY_IP auto-detected (not unknown)" \
  "grep 'GATEWAY_IP=' /mnt/data/telegraf/env 2>/dev/null | grep -qv 'unknown'"

run_test_show "PING-01b" "Gateway IP value" \
  "grep GATEWAY_IP /mnt/data/telegraf/env 2>/dev/null"

run_test "PING-02" "Telegraf ping plugin loaded (no errors)" \
  "! journalctl -u telegraf --no-pager -q 2>/dev/null | grep -qi 'error.*ping'"

run_test "PING-06" "Native ping method configured" \
  "grep -q 'method.*=.*\"native\"' /etc/telegraf/telegraf.conf 2>/dev/null"

# ping binary may be broken on minimal HAOS (BusyBox stub)
if ping -c 1 -W 2 127.0.0.1 >/dev/null 2>&1; then
  run_test "PING-03" "Gateway is pingable" \
    "GW=\$(grep GATEWAY_IP /mnt/data/telegraf/env 2>/dev/null | cut -d= -f2); [ -n \"\$GW\" ] && [ \"\$GW\" != 'unknown' ] && ping -c 1 -W 3 \$GW >/dev/null 2>&1"
  run_test "PING-04" "1.1.1.1 is pingable" \
    "ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1"
  run_test "PING-05" "8.8.8.8 is pingable" \
    "ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1"
else
  # ping broken — verify connectivity via ARP + Telegraf ping metrics
  GW=$(grep GATEWAY_IP /mnt/data/telegraf/env 2>/dev/null | cut -d= -f2)
  run_test "PING-03" "Gateway reachable (ARP table)" \
    "grep -q '${GW:-NO_GW}' /proc/net/arp 2>/dev/null"
  run_test "PING-04" "Telegraf ping plugin reporting data" \
    "journalctl -u telegraf --no-pager -q --since '10 min ago' 2>/dev/null | grep -qi 'ping'"
  skip_test "PING-05" "8.8.8.8 is pingable" "ping binary broken on this build"
fi

suite_end
