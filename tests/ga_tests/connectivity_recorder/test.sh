#!/bin/sh
# Connectivity flight recorder test suite.
# Runs ON the device (service/enable asserts) but the functional asserts also
# work host-side: the recorder sources cleanly with GA_CR_TEST=1 and its pure
# functions (emit / map_connectivity / carrier) need only date+awk+sysfs.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Connectivity Flight Recorder"

# Locate the recorder script: installed path on device, overlay path in-repo.
REC="/usr/sbin/ga-connectivity-recorder"
[ -x "$REC" ] || REC="$SCRIPT_DIR/../../../buildroot-ihost/rootfs-overlay/usr/sbin/ga-connectivity-recorder"

run_test "CFR-01" "recorder script present + executable" \
  "test -x '$REC'"

# Service enable — only meaningful on a booted device where the unit is
# actually installed (guard on the installed script path, not just systemctl:
# a dev laptop has systemctl but not this service).
if [ -x /usr/sbin/ga-connectivity-recorder ] && command -v systemctl >/dev/null 2>&1; then
  run_test "CFR-02" "recorder service enabled" \
    "systemctl is-enabled ga-connectivity-recorder"
  run_test "CFR-03" "recorder ordered after ga-boot-check" \
    "systemctl show -p After ga-connectivity-recorder.service 2>/dev/null | grep -q ga-boot-check"
else
  skip_test "CFR-02" "recorder service enabled" "no systemctl (host run)"
  skip_test "CFR-03" "recorder ordered after ga-boot-check" "no systemctl (host run)"
fi

# --- functional: pure recorder functions -------------------------------------
TMPLOG="$(mktemp 2>/dev/null || echo /tmp/cfr_test_$$.jsonl)"

# emit two events into an isolated log
( export GA_CR_TEST=1 GA_CR_LOG="$TMPLOG"
  . "$REC"
  emit wan none "" nm-connectivity
  emit link down wlan0 ) 2>/dev/null

run_test "CFR-10" "emit writes a wan transition line" \
  "grep -q '\"rung\":\"wan\",\"to\":\"none\"' '$TMPLOG'"
run_test "CFR-11" "emit writes a link line with iface" \
  "grep -q '\"rung\":\"link\",\"to\":\"down\",\"iface\":\"wlan0\"' '$TMPLOG'"

if command -v jq >/dev/null 2>&1; then
  run_test "CFR-12" "every emitted line is valid JSON" \
    "jq -e . '$TMPLOG' >/dev/null"
else
  skip_test "CFR-12" "every emitted line is valid JSON" "jq not present"
fi

run_test "CFR-13" "map_connectivity portal maps to limited" \
  "[ \"\$(GA_CR_TEST=1; . '$REC'; map_connectivity portal)\" = limited ]"
run_test "CFR-14" "map_connectivity unknown maps to empty (skip)" \
  "[ -z \"\$(GA_CR_TEST=1; . '$REC'; map_connectivity unknown)\" ]"

# carrier() via a fake sysfs tree
FAKE_NET="$(mktemp -d 2>/dev/null || echo /tmp/cfr_net_$$)"
mkdir -p "$FAKE_NET/eth0"; printf '0\n' > "$FAKE_NET/eth0/carrier"
run_test "CFR-15" "carrier reads down from sysfs" \
  "[ \"\$(GA_CR_TEST=1 GA_CR_SYS_NET='$FAKE_NET'; . '$REC'; carrier eth0)\" = down ]"
run_test "CFR-16" "carrier reports absent iface" \
  "[ \"\$(GA_CR_TEST=1 GA_CR_SYS_NET='$FAKE_NET'; . '$REC'; carrier wlan9)\" = absent ]"

rm -rf "$TMPLOG" "$FAKE_NET" 2>/dev/null

suite_end
