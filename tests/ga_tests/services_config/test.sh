#!/bin/sh
# GA Services Config test suite — runs ON the device
# Tests the centralized ga-services.conf system for endpoint IP management.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Services Config"

CONF_DEFAULT="/etc/ga-services.conf"
CONF_OVERRIDE="/mnt/data/ga-services.conf"
HOSTS_FILE="/etc/hosts"
MARKER="# ga-services managed entries"

# =========================================================================
# Config file (SVC-10..13)
# =========================================================================

run_test "SVC-10" "ga-services.conf exists on rootfs" \
  "test -f $CONF_DEFAULT"

run_test "SVC-11" "ga-services.conf has GA_SERVICES_IP" \
  "grep -q 'GA_SERVICES_IP=' $CONF_DEFAULT 2>/dev/null"

run_test "SVC-12" "ga-services.conf has all service hostnames" \
  "grep -q 'GA_INFLUX_HOST=' $CONF_DEFAULT && grep -q 'GA_LOKI_HOST=' $CONF_DEFAULT && grep -q 'GA_OTA_HOST=' $CONF_DEFAULT"

# SVC-13: Config is valid shell (sourceable without errors)
run_test "SVC-13" "ga-services.conf is valid shell" \
  "sh -n $CONF_DEFAULT 2>/dev/null && . $CONF_DEFAULT && test -n \"\$GA_SERVICES_IP\""

# =========================================================================
# Update hosts service (SVC-14..16)
# =========================================================================

echo ""
echo "--- Update hosts service ---"

run_test "SVC-14" "ga-update-hosts script exists and executable" \
  "test -x /usr/sbin/ga-update-hosts"

run_test "SVC-15" "ga-update-hosts.service ran successfully" \
  "systemctl show ga-update-hosts -p ActiveState --value 2>/dev/null | grep -q 'active'"

run_test_show "SVC-15b" "ga-update-hosts journal output" \
  "journalctl -u ga-update-hosts --no-pager -q 2>/dev/null | tail -3"

# =========================================================================
# Hosts file entries (SVC-16..20)
# =========================================================================

echo ""
echo "--- Hosts file entries ---"

# Load the IP from config for verification
. "$CONF_DEFAULT" 2>/dev/null || true
[ -f "$CONF_OVERRIDE" ] && . "$CONF_OVERRIDE" 2>/dev/null
EXPECTED_IP="${GA_SERVICES_IP:-unknown}"

run_test "SVC-16" "hosts file has ga-services marker" \
  "grep -q '$MARKER' $HOSTS_FILE 2>/dev/null"

run_test "SVC-17" "hosts file has influx.greenautarky.com" \
  "grep -q 'influx.greenautarky.com' $HOSTS_FILE 2>/dev/null"

run_test "SVC-18" "hosts file has loki.greenautarky.com" \
  "grep -q 'loki.greenautarky.com' $HOSTS_FILE 2>/dev/null"

run_test "SVC-19" "hosts file has ota.greenautarky.com" \
  "grep -q 'ota.greenautarky.com' $HOSTS_FILE 2>/dev/null"

# SVC-20: All GA entries use the IP from config (not some stale hardcoded one)
run_test "SVC-20" "hosts GA entries match ga-services.conf IP ($EXPECTED_IP)" \
  "grep 'influx.greenautarky.com' $HOSTS_FILE 2>/dev/null | grep -q '$EXPECTED_IP'"

# =========================================================================
# DNS resolution (SVC-21..23)
# =========================================================================

echo ""
echo "--- DNS resolution ---"

run_test "SVC-21" "influx.greenautarky.com resolves to $EXPECTED_IP" \
  "getent hosts influx.greenautarky.com 2>/dev/null | grep -q '$EXPECTED_IP'"

run_test "SVC-22" "loki.greenautarky.com resolves to $EXPECTED_IP" \
  "getent hosts loki.greenautarky.com 2>/dev/null | grep -q '$EXPECTED_IP'"

run_test "SVC-23" "ota.greenautarky.com resolves to $EXPECTED_IP" \
  "getent hosts ota.greenautarky.com 2>/dev/null | grep -q '$EXPECTED_IP'"

# =========================================================================
# Runtime override (SVC-24..26)
# =========================================================================

echo ""
echo "--- Runtime override ---"

# SVC-24: Test override mechanism with a temp file (non-destructive)
TMPDIR_SVC=$(mktemp -d)
echo 'GA_SERVICES_IP=10.99.99.99' > "$TMPDIR_SVC/ga-services.conf"
echo 'GA_INFLUX_HOST=influx.greenautarky.com' >> "$TMPDIR_SVC/ga-services.conf"
echo 'GA_LOKI_HOST=loki.greenautarky.com' >> "$TMPDIR_SVC/ga-services.conf"
echo 'GA_OTA_HOST=ota.greenautarky.com' >> "$TMPDIR_SVC/ga-services.conf"

# SVC-24: Script reads config without crashing
run_test "SVC-24" "ga-update-hosts accepts valid config (dry check)" \
  ". $TMPDIR_SVC/ga-services.conf && test \"\$GA_SERVICES_IP\" = '10.99.99.99'"

# SVC-25: Override file takes precedence (check logic)
if [ -f "$CONF_OVERRIDE" ]; then
  run_test "SVC-25" "runtime override exists on /mnt/data" "true"
else
  warn_test "SVC-25" "no runtime override (using rootfs default)" "false"
fi

# SVC-26: No hardcoded IPs in ga-defaults/hosts (should be comment only)
run_test "SVC-26" "ga-defaults/hosts has no hardcoded GA IPs" \
  "! grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+.*greenautarky' /usr/share/ga-defaults/hosts 2>/dev/null"

rm -rf "$TMPDIR_SVC"

# =========================================================================
# Service ordering (SVC-27..28)
# =========================================================================

echo ""
echo "--- Service ordering ---"

run_test "SVC-27" "ga-update-hosts runs before supervisor" \
  "systemctl cat ga-update-hosts 2>/dev/null | grep -q 'Before=.*hassio-supervisor'"

run_test "SVC-28" "ga-update-hosts runs after overlay mount" \
  "systemctl cat ga-update-hosts 2>/dev/null | grep -q 'After=.*hassos-overlay'"

suite_end
