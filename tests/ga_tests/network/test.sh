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

# Tier-1 (error logs) and tier-2 (metrics) shippers are consent-gated by design:
# telegraf has ConditionPathExists=/mnt/data/.ga-consent-metrics, fluent-bit
# (tier-1) has ConditionPathExists=/mnt/data/.ga-consent-error_logs. Without the
# marker the unit is inactive on purpose and its env file does not exist. Tests
# that assert on them must SKIP with the reason, not FAIL — on a fresh device
# without consent they were 12 structural reds (2026-09-02, K31 rc19).
_consent_metrics()    { [ -f /mnt/data/.ga-consent-metrics ]; }
_consent_error_logs() { [ -f /mnt/data/.ga-consent-error_logs ]; }
if _consent_metrics; then
run_test "NET-02" "Telegraf InfluxDB output loaded and no write errors" \
  "journalctl -u telegraf -b 0 --no-pager -q 2>/dev/null | grep -q 'Loaded outputs.*influxdb' && ! journalctl -u telegraf --no-pager -q --since '5 min ago' 2>/dev/null | grep -qi 'failed to write\|connection refused\|timeout'"
else
  skip_test "NET-02" "Telegraf InfluxDB output (tier-2 metrics consent not given)"
fi

if _consent_error_logs; then
run_test "NET-03" "Fluent-Bit Loki output configured and delivering" \
  "journalctl -u fluent-bit -b 0 --no-pager -q 2>/dev/null | grep -q 'loki.greenautarky.com' && ! journalctl -u fluent-bit --no-pager -q --since '5 min ago' 2>/dev/null | grep -qi 'no upstream connections\|connection refused'"
else
  skip_test "NET-03" "Fluent-Bit (tier-1) Loki output (tier-1 error-log consent not given; tier-0 is covered by NET-03b)"
fi

# tier-0 is always on and is what a fresh device actually ships through
run_test "NET-03b" "Fluent-Bit tier-0 active and delivering (no recent Loki errors)" \
  "systemctl is-active fluent-bit-tier0 >/dev/null 2>&1 && ! journalctl -u fluent-bit-tier0 --no-pager -q --since '5 min ago' 2>/dev/null | grep -qiE 'no upstream|broken connection|HTTP status=[45]'"

if _consent_metrics && _consent_error_logs; then
run_test "NET-04" "Telemetry services active with no recent errors" \
  "systemctl is-active telegraf >/dev/null 2>&1 && systemctl is-active fluent-bit >/dev/null 2>&1 && ! journalctl -u telegraf -u fluent-bit --no-pager -q --since '5 min ago' 2>/dev/null | grep -qi 'error.*output\|failed to flush\|connection refused'"
else
  skip_test "NET-04" "telegraf + fluent-bit active (consent-gated tiers not enabled on this device)"
fi

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

# Split, because the old single check conflated two different failures and
# reported the wrong one. It asserted that /index.txt contains "OTA" and called
# a miss "endpoint unreachable" — so a served-but-empty manifest and a dead
# network looked identical. Measured on K31 2026-07-30: the endpoint answered
# HTTP 404 in 0.33 s over the public IP AND over the mesh IP, i.e. DNS, routing
# and TLS all worked, and the test still said unreachable.
#
# A 404 proves reachability. Same lesson as the fleet-manager /healthz probe,
# where a 404 is the normal response and still evidences a live service.
run_test "NET-16b" "OTA endpoint reachable from device (any HTTP response)" \
  "CODE=\$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 10 -m 20 https://ota.greenautarky.com/ 2>/dev/null); \
   [ -n \"\$CODE\" ] && [ \"\$CODE\" != '000' ]"

# NET-16c asserts what the OTA path actually depends on: a bundle is fetchable
# with STRICT TLS.
#
# I first wrote this as "/index.txt contains OTA", inheriting that from the old
# NET-16b. Then I checked, and nothing in this repo, ga_manager or
# ga-fleet-manager reads index.txt — it exists only on a decommissioned host and
# 404s on the current one. So it was a test with no consumer, asserting a legacy
# artifact.
#
# What OTA genuinely needs is what ga-rauc-install does: fetch
# /releases/<version>/haos_ihost-<version>.raucb with `curl --fail` and NO -k.
# The TLS strictness is the load-bearing part — measured 2026-07-30, the
# decommissioned host still serves that path but its certificate expired
# 2026-06-30, so a lenient probe reports success (HTTP 200 with -k) where the
# real installer fails (exit 60, ssl_verify=10). A check that is more forgiving
# than the code it guards is worse than none.
#
# -I so this stays a HEAD request: the bundle is ~240 MB and the point is
# reachability + trust, not a download.
_OTA_VER="$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"')"
if [ -n "$_OTA_VER" ]; then
  run_test "NET-16c" "OTA bundle for $_OTA_VER fetchable with STRICT TLS (as ga-rauc-install does)" \
    "curl -sf -I --connect-timeout 10 -m 25 -o /dev/null \
       https://ota.greenautarky.com/releases/${_OTA_VER}/haos_ihost-${_OTA_VER}.raucb"
else
  skip_test "NET-16c" "OTA bundle fetch" "cannot read VERSION_ID from /etc/os-release"
fi

suite_end
