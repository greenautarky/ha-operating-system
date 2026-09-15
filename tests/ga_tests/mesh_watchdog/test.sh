#!/bin/sh
# Mesh watchdog suite — runs ON the device.
#
# Proves the thing is INSTALLED, RUNNING and SAYING SOMETHING. The logic itself
# is proven without hardware by selftest.sh in the same directory (which drives
# this exact script with stub commands, on every pull request); what only a
# device can answer is whether the unit shipped, whether the timer is actually
# firing, and whether the discriminator's inputs exist here — the three ways a
# correct script still ends up doing nothing on a real box.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Mesh watchdog"

SHARE="/mnt/data/supervisor/share/ga-mesh-watchdog.json"
# Two timer periods. Older than that and the timer is not firing, whatever
# `systemctl list-timers` claims.
MAX_AGE_S=120

run_test "MESH-01" "ga-mesh-watchdog is installed and executable" \
  "test -x /usr/sbin/ga-mesh-watchdog"

run_test "MESH-02" "ga-mesh-watchdog.service is present" \
  "systemctl cat ga-mesh-watchdog.service >/dev/null 2>&1"

run_test "MESH-03" "ga-mesh-watchdog.timer is ACTIVE (not merely enabled)" \
  "[ \"\$(systemctl is-active ga-mesh-watchdog.timer 2>/dev/null)\" = active ]"

run_test_show "MESH-04" "…and it has a next elapse scheduled" \
  "systemctl show -p NextElapseUSecRealtime --value ga-mesh-watchdog.timer 2>/dev/null | grep -qv '^$' && systemctl show -p NextElapseUSecRealtime --value ga-mesh-watchdog.timer"

run_test "MESH-05" "ga-resolve-ota publishes the WAN verdict the watchdog reads" \
  "test -r /run/ga-resolve-ota.state && jq -e 'has(\"wan_up\")' /run/ga-resolve-ota.state >/dev/null"

# The timer's first run is OnBootSec=4min; give a freshly booted device that
# long before demanding a file, then assert for real either way.
run_test_ready "MESH-06" "the /share bridge file exists" \
  "test -f $SHARE" 300 \
  "test -f $SHARE"

run_test_show "MESH-07" "…and it is fresher than ${MAX_AGE_S}s (the timer is really firing)" \
  "age=\$(( \$(date +%s) - \$(jq -r '.ts // 0' $SHARE 2>/dev/null || echo 0) )); echo \"\${age}s old\"; [ \"\$age\" -ge 0 ] && [ \"\$age\" -le $MAX_AGE_S ]"

# `unknown` is the fail-closed verdict: an input could not be read. It is the
# correct answer to a blind tick and the WRONG answer on a converged device —
# it means the watchdog is installed and can never act.
run_test_show "MESH-08" "state is a real verdict, not 'unknown' (a converged device must be measurable)" \
  "s=\$(jq -r '.state // \"missing\"' $SHARE 2>/dev/null); echo \"state=\$s detail=\$(jq -r '.detail // \"\"' $SHARE 2>/dev/null)\"; [ \"\$s\" = alive ] || [ \"\$s\" = dead ] || [ \"\$s\" = outage ]"

run_test "MESH-09" "the file carries the fields the fleet-manager needs" \
  "jq -e 'has(\"ts\") and has(\"state\") and has(\"consecutive_dead\") and has(\"restarts_24h\") and has(\"last_restart_ts\") and has(\"wan_up\") and has(\"client_claims_connected\")' $SHARE >/dev/null"

# A restart in the last 24 h is not a failure of this suite — it is the
# watchdog WORKING — but it is never normal, so it is reported loudly.
run_test_show "MESH-10" "no mesh-client restart in the last 24 h (a restart is a finding, not a fault)" \
  "n=\$(jq -r '.restarts_24h // 0' $SHARE 2>/dev/null); echo \"restarts_24h=\$n last_restart_ts=\$(jq -r '.last_restart_ts // 0' $SHARE 2>/dev/null)\"; [ \"\$n\" = 0 ]"

# The durable half of the once-per-hour limit. If this directory is not
# writable the limit does not survive a reboot, and a boot loop could restart
# the mesh client every four minutes for ever.
run_test "MESH-11" "the restart ledger lives on persistent storage" \
  "test -d /mnt/data/netbird && touch /mnt/data/netbird/.ga-mesh-watchdog-writetest && rm -f /mnt/data/netbird/.ga-mesh-watchdog-writetest"

skip_test "MESH-12" "a dead mesh restarts the client" "destructive — bench nft injection, see the PR body"

suite_end
