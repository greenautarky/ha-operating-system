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
MAX_AGE_S=300

run_test "MESH-01" "ga-mesh-watchdog is installed and executable" \
  "test -x /usr/sbin/ga-mesh-watchdog"

run_test "MESH-02" "ga-mesh-watchdog.service is present" \
  "systemctl cat ga-mesh-watchdog.service >/dev/null 2>&1"

run_test "MESH-03" "ga-mesh-watchdog.timer is ACTIVE (not merely enabled)" \
  "[ \"\$(systemctl is-active ga-mesh-watchdog.timer 2>/dev/null)\" = active ]"

# The timer is OnBootSec/OnUnitActiveSec = MONOTONIC. NextElapseUSecRealtime is
# only ever set for OnCalendar timers, so on this unit it is ALWAYS empty and
# the old check could not pass on any device (systemd prints the monotonic value
# humanised, e.g. "2h 37.127221s" on K31, so it is not tested for digits) (K31 BOSv1.5.1-rc1/rc3,
# 2026-10-13). selftest.sh extracts this very line (MESH04_CMD) and runs it
# against a stub systemctl - keep it on ONE line, single-quoted.
MESH04_CMD='n=$(systemctl show -p NextElapseUSecMonotonic --value ga-mesh-watchdog.timer 2>/dev/null); echo "next elapse (monotonic)=${n:-empty}"; case "$n" in ""|0|n/a|infinity) false ;; *) true ;; esac'
run_test_show "MESH-04" "…and it has a next elapse scheduled" "$MESH04_CMD"

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
  "s=\$(jq -r '.state // \"missing\"' $SHARE 2>/dev/null); echo \"state=\$s detail=\$(jq -r '.detail // \"\"' $SHARE 2>/dev/null)\"; case \"\$s\" in alive|dead|cloud_down|held|reboot_capped) true ;; *) false ;; esac"

run_test "MESH-09" "the file carries the fields the fleet-manager needs" \
  "jq -e 'has(\"ts\") and has(\"state\") and has(\"consecutive_dead\") and has(\"restarts_24h\") and has(\"last_restart_ts\") and has(\"cloud_reachable\") and has(\"stage\") and has(\"last_action\") and has(\"reboots_24h\")' $SHARE >/dev/null"

# A restart in the last 24 h is not a failure of this suite — it is the
# watchdog WORKING — but it is never normal, so it is reported loudly.
run_test_show "MESH-10" "no mesh action and no watchdog reboot in the last 24 h (an action is a finding, not a fault)" \
  "n=\$(jq -r '.restarts_24h // 0' $SHARE 2>/dev/null); r=\$(jq -r '.reboots_24h // 0' $SHARE 2>/dev/null); echo \"actions_24h=\$n reboots_24h=\$r last_action=\$(jq -r '.last_action // \"\"' $SHARE 2>/dev/null)\"; [ \"\$n\" = 0 ] && [ \"\$r\" = 0 ]"

# The durable half of the one-reboot-per-24-h limit. If this directory is not
# writable the limit does not survive a reboot, and a dead path could become a
# boot loop.
run_test "MESH-11" "the restart ledger lives on persistent storage" \
  "test -d /mnt/data/netbird && touch /mnt/data/netbird/.ga-mesh-watchdog-writetest && rm -f /mnt/data/netbird/.ga-mesh-watchdog-writetest"

skip_test "MESH-12" "a dead mesh climbs the ladder; a blocked NetBird cloud does not" "destructive — bench nft injection on K31, see the PR body"

suite_end
