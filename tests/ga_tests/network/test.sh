#!/bin/sh
# Network configuration test suite - runs ON the device
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Network"

run_test "NET-01" "Static DNS entries for GA services" \
  "grep -q 'greenautarky' /etc/hosts 2>/dev/null"

run_test_show "NET-01b" "DNS entries" \
  "grep greenautarky /etc/hosts 2>/dev/null"

# Verify telemetry endpoints work by checking output loaded + no persistent errors
# (Both services run silently on success — no "wrote batch" messages at info level)
run_test "NET-02" "Telegraf InfluxDB output loaded and no write errors" \
  "journalctl -u telegraf -b 0 --no-pager -q 2>/dev/null | grep -q 'Loaded outputs.*influxdb' && ! journalctl -u telegraf --no-pager -q --since '5 min ago' 2>/dev/null | grep -qi 'failed to write\|connection refused\|timeout'"

run_test "NET-03" "Fluent-Bit Loki output configured and delivering" \
  "journalctl -u fluent-bit -b 0 --no-pager -q 2>/dev/null | grep -q 'loki.greenautarky.com' && ! journalctl -u fluent-bit --no-pager -q --since '5 min ago' 2>/dev/null | grep -qi 'no upstream connections\|connection refused'"

run_test "NET-04" "Telemetry services active with no recent errors" \
  "systemctl is-active telegraf >/dev/null 2>&1 && systemctl is-active fluent-bit >/dev/null 2>&1 && ! journalctl -u telegraf -u fluent-bit --no-pager -q --since '5 min ago' 2>/dev/null | grep -qi 'error.*output\|failed to flush\|connection refused'"

run_test "NET-05" "Default gateway detected" \
  "ip route | grep -q '^default'"

# ping binary may be broken on minimal HAOS (BusyBox stub returns 1 always)
if ping -c 1 -W 2 127.0.0.1 >/dev/null 2>&1; then
  run_test "NET-06" "Internet connectivity (ping 1.1.1.1)" \
    "ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1"
else
  # Fallback: check gateway in ARP table (proves L2/L3 works)
  run_test "NET-06" "Network connectivity (gateway in ARP table)" \
    "GW=\$(ip route | grep '^default' | awk '{print \$3}'); grep -q \"\$GW\" /proc/net/arp 2>/dev/null"
fi

run_test_show "NET-GW" "Default gateway" \
  "ip route | grep '^default' | head -1 | awk '{print \$3}'"

suite_end
