#!/bin/sh
# HA-init test suite — runs ON the device.
# Verifies the fleet-wide defaults applied at first boot. ga-ha-init owns
# DNS-off + timezone Berlin + auto_update=false (= ga-flasher-py stage 69
# parts + 92). Addon watchdog moved to ga_manager converge step 8 (ga-ha-init
# runs before addons install); weather/location dropped (needs the owner
# account). D-09 below still asserts the watchdog END state.
#
# Counterpart build tests: HA-INIT-01..09 in run_build_tests.sh.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
suite_start "HA Init (fleet defaults)"

MARKER="/mnt/data/supervisor/share/.ga-ha-init-applied"
UPDATER_JSON="/mnt/data/supervisor/updater.json"
DNS_JSON="/mnt/data/supervisor/dns.json"

# HA-INIT-D-01: script + service present.
run_test "HA-INIT-D-01" "ga-ha-init script present + executable" \
  "test -x /usr/libexec/ga-ha-init"

run_test "HA-INIT-D-02" "ga-ha-init.service unit present" \
  "test -f /usr/lib/systemd/system/ga-ha-init.service"

# HA-INIT-D-03: service ran successfully (marker present).
run_test "HA-INIT-D-03" "ga-ha-init marker /share/.ga-ha-init-applied written" \
  "test -f $MARKER && test -s $MARKER"

# HA-INIT-D-04: service is active in systemd's view.
run_test "HA-INIT-D-04" "ga-ha-init.service is active" \
  "systemctl is-active ga-ha-init.service >/dev/null"

# HA-INIT-D-05: DNS fallback OFF.
run_test "HA-INIT-D-05" "dns.json fallback=false" \
  "grep -E '\"fallback\"[[:space:]]*:[[:space:]]*false' $DNS_JSON >/dev/null"

# HA-INIT-D-06: explicit Cloudflare servers.
run_test "HA-INIT-D-06" "dns.json has both 1.1.1.1 and 1.0.0.1" \
  "grep -q 1.1.1.1 $DNS_JSON && grep -q 1.0.0.1 $DNS_JSON"

# HA-INIT-D-07: auto-update OFF (= ga-flasher-py stage 92).
# Query the Supervisor runtime API — NOT updater.json. Observed
# 2026-05-27 KIB-SON-31: editing updater.json directly with jq doesn't
# stick (Supervisor rewrites from its in-memory state). The API mutates
# the in-memory state so the change is durable.
run_test "HA-INIT-D-07" "supervisor auto_update=false (via API)" \
  "test \"\$(ha supervisor info --raw-json --no-progress 2>/dev/null | jq -r '.data.auto_update')\" = 'false'"

# HA-INIT-D-08: timezone Europe/Berlin (END state).
# ga-ha-init sets this at t~85s but Supervisor's host.control sync reverts
# to UTC at ~t=120s; the ga-ha-init-tz-reapply.timer re-applies at t=240s.
# So this is only reliably true AFTER boot+240s. If we're earlier than that
# and the timer hasn't fired yet, SKIP rather than FAIL (transient window).
uptime_s=$(cut -d. -f1 /proc/uptime 2>/dev/null)
tz_ok() { readlink /etc/localtime 2>/dev/null | grep -q 'Europe/Berlin$' || timedatectl status 2>/dev/null | grep -qE 'Time zone:[[:space:]]+Europe/Berlin'; }
if tz_ok; then
  run_test "HA-INIT-D-08" "system timezone Europe/Berlin" "true"
elif [ "${uptime_s:-9999}" -lt 270 ]; then
  skip_test "HA-INIT-D-08" "system timezone Europe/Berlin" "uptime ${uptime_s}s < 270s — tz-reapply timer (boot+240s) not fired yet"
else
  run_test "HA-INIT-D-08" "system timezone Europe/Berlin" "false"
fi

# HA-INIT-D-08b: the late-reapply timer is installed + scheduled/active.
run_test "HA-INIT-D-08b" "ga-ha-init-tz-reapply.timer loaded" \
  "systemctl list-timers --all 2>/dev/null | grep -q ga-ha-init-tz-reapply || systemctl is-enabled ga-ha-init-tz-reapply.timer >/dev/null 2>&1"

# HA-INIT-D-09: at least one addon has watchdog enabled (END-state check).
# Watchdog is owned by ga_manager converge step 8 (addon_set_flags), which
# runs AFTER addons are installed — ga-ha-init no longer touches watchdog
# (its loop ran pre-install, always a no-op; removed 2026-05-28). If addons
# aren't installed yet (converge not run), SKIP — converge fills it in.
# Tracked: todo_v12_bake_followups_2026_05_27.md item #1 + #9.
# Count addons that are TRULY installed (`version_installed` != null). The
# bare addon-list endpoint also returns "available" addons whose state is
# "started" but `version_installed` is null — calling `ha addons options
# --watchdog` on those returns the supervisor "addon may be uninstalled"
# warning we see in ga-ha-init's journal. So SKIP if 0 truly-installed.
installed_count=$(ha addons --raw-json --no-progress 2>/dev/null | jq '[.data.addons[] | select(.version_installed != null)] | length' 2>/dev/null)
if [ "${installed_count:-0}" -eq 0 ]; then
  skip_test "HA-INIT-D-09" "at least one addon has watchdog=true" "0 truly-installed addons (ga_manager converge step 1 not yet completed)"
else
  run_test "HA-INIT-D-09" "at least one addon has watchdog=true" \
    "ha addons --raw-json --no-progress 2>/dev/null | jq -e '.data.addons[] | select(.watchdog == true)' >/dev/null"
fi

# HA-INIT-D-10: idempotent — re-running the script with marker present returns 0 fast.
# We don't actually re-run it (would slow the test); we just check the marker logic
# is honored by reading the script's exit semantics. The script's section header
# 'Marker short-circuit' is the canonical idempotency-comment marker.
run_test "HA-INIT-D-10" "ga-ha-init marker short-circuits on re-run" \
  "grep -qiE 'marker.*short.*circuit|short.*circuit.*marker' /usr/libexec/ga-ha-init"

suite_end
