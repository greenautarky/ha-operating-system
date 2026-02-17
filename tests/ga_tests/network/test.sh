#!/bin/sh
# Network configuration test suite - runs ON the device
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Network"

run_test "NET-01" "Static DNS entries for GA services" \
  "grep -q 'greenautarky' /etc/hosts 2>/dev/null"

run_test_show "NET-01b" "DNS entries" \
  "grep greenautarky /etc/hosts 2>/dev/null"

run_test "NET-02" "InfluxDB endpoint reachable" \
  "nc -z -w5 influx.greenautarky.com 8086 2>/dev/null"

run_test "NET-03" "Loki endpoint reachable" \
  "nc -z -w5 loki.greenautarky.com 3100 2>/dev/null"

run_test "NET-04" "Loki health check" \
  "wget -qO- http://loki.greenautarky.com:3100/ready 2>/dev/null | grep -qi ready"

run_test "NET-05" "Default gateway detected" \
  "ip route | grep -q '^default'"

run_test "NET-06" "Internet connectivity (ping 1.1.1.1)" \
  "ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1"

run_test_show "NET-GW" "Default gateway" \
  "ip route | grep '^default' | head -1 | awk '{print \$3}'"

suite_end
