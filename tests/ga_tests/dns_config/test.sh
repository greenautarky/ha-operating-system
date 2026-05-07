#!/bin/sh
# DNS Config test suite — runs ON the device
# Verifies the GA Supervisor DNS defaults set by ha-supervisor patch
# (commit 6b427484: feat(dns): GA defaults — explicit Cloudflare servers + fallback off).
#
# Why these defaults matter: with upstream's defaults (servers=[], fallback=true),
# HA Core's PTR sweeps for the local subnet escalate to DoT (1.1.1.1:853) when the
# DHCP-derived locals DNS doesn't answer RFC1918 PTRs (typical on captive WiFi /
# hotspot). The DoT TLS handshake hangs ~75-95s per query → hassio_dns spikes to
# 180% CPU. Measured 2026-05-07 on kib-son-0; full root cause analysis in
# ga-flasher-py TODO §"DNS Fallback CPU Spike".
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "DNS Config"

DNS_JSON="/mnt/data/supervisor/dns.json"
COREDNS_HOST="172.30.32.3"

# =========================================================================
# Container + persisted config (DNS-01..04)
# =========================================================================

run_test "DNS-01" "hassio_dns container running" \
  "docker inspect -f '{{.State.Status}}' hassio_dns 2>/dev/null | grep -q running"

run_test "DNS-02" "supervisor dns.json exists" \
  "test -f $DNS_JSON"

# Persisted config in dns.json reflects the GA defaults (or matches them after
# explicit configure). Use grep on the JSON; jq is not always available in HAOS.
run_test "DNS-03" "dns.json has fallback=false" \
  "grep -E '\"fallback\"[[:space:]]*:[[:space:]]*false' $DNS_JSON 2>/dev/null"

run_test "DNS-04" "dns.json has Cloudflare servers (1.1.1.1 + 1.0.0.1)" \
  "grep -q '1.1.1.1' $DNS_JSON 2>/dev/null && grep -q '1.0.0.1' $DNS_JSON 2>/dev/null"

# =========================================================================
# Live Supervisor view (DNS-05..08)
# =========================================================================

echo ""
echo "--- Live Supervisor DNS state ---"

# `ha dns info` outputs YAML. Cache the output once for subsequent checks.
DNS_INFO=$(ha --no-progress dns info 2>/dev/null || true)

run_test_show "DNS-05a" "ha dns info — fallback line" \
  "echo \"\$DNS_INFO\" | grep '^fallback:'"

run_test "DNS-05" "live fallback=false" \
  "echo \"\$DNS_INFO\" | grep -q '^fallback: false'"

run_test "DNS-06" "live servers contain dns://1.1.1.1" \
  "echo \"\$DNS_INFO\" | grep -q 'dns://1.1.1.1'"

run_test "DNS-07" "live servers contain dns://1.0.0.1" \
  "echo \"\$DNS_INFO\" | grep -q 'dns://1.0.0.1'"

run_test_show "DNS-08" "ha dns info — servers block" \
  "echo \"\$DNS_INFO\" | awk '/^servers:/{p=1; next} /^[a-z]/{p=0} p'"

# =========================================================================
# Forward + GA hostname resolution (DNS-10..13)
# =========================================================================

echo ""
echo "--- Resolution via Supervisor CoreDNS ---"

# Query CoreDNS directly to make sure THIS resolver works (not the host's NM-DNS).
# nslookup in busybox returns nonzero on partial failure; check via output match.
run_test "DNS-10" "release-assets.githubusercontent.com resolves (HACS-critical)" \
  "nslookup release-assets.githubusercontent.com $COREDNS_HOST 2>/dev/null | grep -E 'Address[: ]+[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+' | grep -v '$COREDNS_HOST'"

run_test "DNS-11" "github.com resolves" \
  "nslookup github.com $COREDNS_HOST 2>/dev/null | grep -E 'Address[: ]+[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+' | grep -v '$COREDNS_HOST'"

# GA hostnames must resolve via Supervisor /etc/hosts (commit 8f911d6 etc.) before
# any external query. Verify the IP matches what's in ga-services.conf.
EXPECTED_GA_IP=$(. /etc/ga-services.conf 2>/dev/null && echo "$GA_SERVICES_IP")
[ -f /mnt/data/ga-services.conf ] && EXPECTED_GA_IP=$(. /mnt/data/ga-services.conf 2>/dev/null && echo "$GA_SERVICES_IP")
EXPECTED_GA_IP="${EXPECTED_GA_IP:-100.126.142.217}"

run_test "DNS-12" "ota.greenautarky.com resolves to GA IP ($EXPECTED_GA_IP)" \
  "nslookup ota.greenautarky.com $COREDNS_HOST 2>/dev/null | grep -q '$EXPECTED_GA_IP'"

run_test "DNS-13" "influx.greenautarky.com resolves to GA IP ($EXPECTED_GA_IP)" \
  "nslookup influx.greenautarky.com $COREDNS_HOST 2>/dev/null | grep -q '$EXPECTED_GA_IP'"

# =========================================================================
# CPU spike protection (DNS-20..21)
# =========================================================================
# These are the actual regression guards for the bug that motivated the GA defaults.
# If someone (or upstream) re-enables fallback with empty servers AND the locals DNS
# doesn't answer RFC1918 PTRs, hassio_dns spikes to 100-200% CPU sustained.
# Sample over ~10s and assert below a generous threshold.

echo ""
echo "--- hassio_dns resource check (10s sample) ---"

# Sum CPU% across 5 samples 2s apart. Expected idle-state: < 5% sustained.
# Threshold of 50 is generous (sustained spike is 140-220% per docker stats).
CPU_SUM=0
SAMPLES=0
for i in 1 2 3 4 5; do
  CPU=$(docker stats hassio_dns --no-stream --format '{{.CPUPerc}}' 2>/dev/null | tr -d '%' | awk '{printf "%d", $1}')
  if [ -n "$CPU" ]; then
    CPU_SUM=$((CPU_SUM + CPU))
    SAMPLES=$((SAMPLES + 1))
  fi
  [ "$i" -lt 5 ] && sleep 2
done
if [ "$SAMPLES" -gt 0 ]; then
  CPU_AVG=$((CPU_SUM / SAMPLES))
else
  CPU_AVG=0
fi

run_test_show "DNS-20" "hassio_dns avg CPU over 10s = ${CPU_AVG}% (threshold 50)" \
  "[ \"$CPU_AVG\" -lt 50 ]"

# Memory sanity. Healthy hassio_dns sits at ~3-5 MiB. The DoT-loop bug grows it
# to ~30 MiB. Threshold of 80 MiB allows headroom for legitimate workloads.
MEM_MB=$(docker stats hassio_dns --no-stream --format '{{.MemUsage}}' 2>/dev/null | awk -F'/' '{print $1}' | sed 's/MiB//; s/[[:space:]]//g' | awk '{printf "%d", $1}')
MEM_MB="${MEM_MB:-0}"

run_test_show "DNS-21" "hassio_dns memory = ${MEM_MB} MiB (threshold 80)" \
  "[ \"$MEM_MB\" -lt 80 ]"

# =========================================================================
# CoreDNS query log — sanity check for PTR loops (DNS-30)
# =========================================================================
# If the bug is active, the log fills with thousands of PTR queries to RFC1918
# addresses, each ending in "context deadline exceeded". One or two over a normal
# minute is fine; > 20 is the smoking-gun pattern from the 2026-05-07 incident.

echo ""
echo "--- CoreDNS recent query log ---"

# grep -c exits 1 when zero matches; suppress with || true so we get a clean number
PTR_TIMEOUTS=$(docker logs hassio_dns --since 60s 2>&1 | grep -c "in-addr.arpa.*context deadline exceeded" || true)
PTR_TIMEOUTS=$(echo "$PTR_TIMEOUTS" | head -1 | tr -d '[:space:]')
PTR_TIMEOUTS="${PTR_TIMEOUTS:-0}"

run_test_show "DNS-30" "RFC1918 PTR DoT-timeouts in last 60s = ${PTR_TIMEOUTS} (threshold 20)" \
  "[ \"$PTR_TIMEOUTS\" -lt 20 ]"

suite_end
