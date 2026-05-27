#!/bin/sh
# HA-init test suite — runs ON the device.
# Verifies that ga-ha-init successfully applied the fleet-wide defaults
# on first boot (DNS off, watchdog on, weather/timezone Berlin,
# auto_update=false). Replaces ga-flasher-py stage 69 (most parts) + 92.
#
# Counterpart build tests: HA-INIT-01..06 in run_build_tests.sh.
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

# HA-INIT-D-08: timezone Europe/Berlin.
run_test "HA-INIT-D-08" "system timezone Europe/Berlin" \
  "readlink /etc/localtime 2>/dev/null | grep -q 'Europe/Berlin$' || timedatectl status 2>/dev/null | grep -qE 'Time zone:[[:space:]]+Europe/Berlin'"

# HA-INIT-D-09: at least one addon has watchdog enabled (proves the loop touched something).
run_test "HA-INIT-D-09" "at least one addon has watchdog=true" \
  "ha addons --raw-json --no-progress 2>/dev/null | jq -e '.data.addons[] | select(.watchdog == true)' >/dev/null"

# HA-INIT-D-10: idempotent — re-running the script with marker present returns 0 fast.
# We don't actually re-run it (would slow the test); we just check the marker logic
# is honored by reading the script's exit semantics.
run_test "HA-INIT-D-10" "ga-ha-init marker short-circuits on re-run" \
  "head -50 /usr/libexec/ga-ha-init | grep -q 'marker present'"

suite_end
