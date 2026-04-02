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

# --- NM connectivity check ---

# NET-07: NM connectivity check configured
run_test "NET-07" "NM connectivity check configured" \
  "grep -q 'checkonline.greenautarky.com' /etc/NetworkManager/NetworkManager.conf 2>/dev/null"

# NET-08: NM reports online
NM_STATE=$(nmcli -t -f CONNECTIVITY general 2>/dev/null || echo "unknown")
run_test_show "NET-08" "NM connectivity state is 'full' (got: $NM_STATE)" \
  "[ '$NM_STATE' = 'full' ]"

# NET-09: GA connectivity endpoint reachable
run_test "NET-09" "checkonline.greenautarky.com reachable" \
  "curl -sf --connect-timeout 5 https://checkonline.greenautarky.com/online.txt 2>/dev/null | grep -q 'NetworkManager is online'"

# --- Ethernet disable state tests ---

# NET-13: Management script always available
run_test "NET-13" "ga-manage-ethernet script available" \
  "test -x /usr/sbin/ga-manage-ethernet"

if [ -f /mnt/data/ga-env.conf ] && grep -q '^GA_ETHERNET_DISABLED=true' /mnt/data/ga-env.conf 2>/dev/null; then
  # Ethernet is disabled — verify the state is correct
  run_test "NET-10" "Ethernet disabled flag set" "true"

  run_test "NET-11" "eth0 is down when disabled" \
    "! nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep -q '^eth0:connected'"

  run_test "NET-12" "WiFi active when Ethernet disabled" \
    "nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep -q '^wlan0:connected'"
else
  skip_test "NET-10" "Ethernet disabled flag set (not disabled)"
  skip_test "NET-11" "eth0 down when disabled (not disabled)"
  skip_test "NET-12" "WiFi active when disabled (not disabled)"
fi

# --- Supervisor DNS (GA entries in CoreDNS, written by Supervisor fork) ---

# NET-14: CoreDNS hosts file has GA entries (written by Supervisor _init_hosts)
DNS_HOSTS_14="/mnt/data/supervisor/dns/hosts"
run_test "NET-14" "CoreDNS hosts file has GA entries (Supervisor-managed)" \
  "test -f $DNS_HOSTS_14 && grep -q 'greenautarky' $DNS_HOSTS_14 2>/dev/null"

# NET-15: CoreDNS hosts has GA entries
DNS_HOSTS="/mnt/data/supervisor/dns/hosts"
if [ -f "$DNS_HOSTS" ]; then
  run_test "NET-15a" "CoreDNS hosts has ota.greenautarky.com" \
    "grep -q 'ota.greenautarky.com' $DNS_HOSTS"

  run_test "NET-15b" "CoreDNS hosts has influx.greenautarky.com" \
    "grep -q 'influx.greenautarky.com' $DNS_HOSTS"

  run_test "NET-15c" "CoreDNS hosts has loki.greenautarky.com" \
    "grep -q 'loki.greenautarky.com' $DNS_HOSTS"
else
  run_test "NET-15a" "CoreDNS hosts file exists" "false"
  run_test "NET-15b" "CoreDNS hosts has influx" "false"
  run_test "NET-15c" "CoreDNS hosts has loki" "false"
fi

# NET-16: Supervisor can resolve GA services
run_test "NET-16a" "Supervisor resolves ota.greenautarky.com" \
  "docker exec hassio_supervisor sh -c 'getent hosts ota.greenautarky.com' >/dev/null 2>&1"

run_test "NET-16b" "OTA endpoint reachable from device" \
  "curl -sfk --connect-timeout 10 https://ota.greenautarky.com/index.txt 2>/dev/null | grep -q 'OTA'"

suite_end
