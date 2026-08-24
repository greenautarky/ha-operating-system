#!/bin/sh
# Addons Running — is every pinned add-on INSTALLED, UP and ANSWERING, probed
# locally, independent of the fleet-manager?
#
# WHY THIS SUITE EXISTS
# =====================
# Stage 2 (2026-08-20) moved every fleet add-on onto new base images. The
# builds were green, the CVE gates were green — and none of that proves the
# add-on RUNS on a device: pandas jumped a major (2.2.3 -> 3.0.3, proven by
# import only), mosquitto's go-auth is a CGO plugin on a new libc, hardware-
# control jumped a Node major. "Merged != shipped != working" — this suite is
# the WORKING line, and it deliberately asks the device itself (docker,
# localhost) rather than the fleet-manager, so it works on a bench device
# that no fm knows about, and keeps working when fm is down.
#
# Run on a PROVISIONED device (after converge). On a fresh unprovisioned
# flash everything here is legitimately red — that is the suite proving it
# can fail, not a defect.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Addons Running (provisioned device, no fleet-manager)"

EXP="$SCRIPT_DIR/../os_integrity/expected.env"
if [ ! -s "$EXP" ]; then
  run_test "ADR-00" "expected.env present (shared with os_integrity)" "false"
  suite_end; exit 1
fi
. "$EXP"

# Container for a slug: Supervisor names them addon_<hash>_<slug> (config.yaml
# slugs), but the STORE slug and the pin key differ for some add-ons
# (ga_influxdbv1 pin -> store slug ga_influxdbv1, container matches too).
ctr_of() { docker ps --format '{{.Names}}' 2>/dev/null | grep -E "^addon_.*_$1\$" | head -1; }
up() { [ -n "$(ctr_of "$1")" ]; }

# READINESS: on a fresh flash converge installs and starts the managed add-ons
# over several minutes. Wait (bounded) for the core managed set to be up before
# asserting each one — otherwise the whole suite red-flags a system that is
# simply still converging. On timeout the checks run anyway (a genuine
# converge failure must fail loudly, not be skipped). 15 min covers a cold
# fresh-flash converge incl. private-GHCR pulls.
if ! wait_for 900 'test "$(docker ps --format "{{.Names}}" | grep -c "^addon_")" -ge 5'; then
  echo "  (converge readiness timed out after 900s — asserting current state anyway)"
fi

# --- up-ness, per pinned add-on -------------------------------------------
run_test_show "ADR-01" "ga_manager container Up" 'up ga_manager'
run_test_show "ADR-02" "ga_mosquitto container Up" 'up ga_mosquitto'
run_test_show "ADR-03" "ga_influxdbv1 container Up" 'up ga_influxdbv1'
run_test_show "ADR-04" "ga_default_addon container Up" 'up ga_default_addon'
run_test_show "ADR-05" "ga_hmvapp_addon container Up" 'up ga_hmvapp_addon'
run_test_show "ADR-06" "ga_ihosthardwarecontrol container Up" 'up ga_ihosthardwarecontrol'
run_test_show "ADR-07" "ga_zigbee2mqtt container Up" 'up ga_zigbee2mqtt'

# The flasher is the deliberate exception: ga_manager >= 0.121.0 STOPS it
# (finding 2026-08-19: unauthenticated :8324 with host_network). Running is
# the DEFECT here.
run_test_show "ADR-08" "dongle flasher NOT running (ga_manager keeps it stopped)" \
  '! docker ps --format "{{.Names}}" 2>/dev/null | grep -qiE "flasher"'

# --- does each one actually WORK? -----------------------------------------
# mosquitto: broker listening AND the CGO go-auth plugin registered. A green
# container with a dead .so is exactly what the base migration could produce.
run_test_show "ADR-10" "mosquitto: port 1883 listening on the host" \
  'netstat -tln 2>/dev/null | grep -q ":1883 "'
# Probe the BEHAVIOUR, not the startup log: docker rotates json logs, so on a
# container up for days the registration lines are gone and a log grep goes
# false-red (measured on K31 2026-08-24: 3-day-old container, log starts a day
# after boot, plugin working fine). An anonymous connect being REFUSED is
# go-auth enforcing auth — provable at any container age. A dead .so would mean
# either no broker (ADR-10 catches that) or an ACCEPTED anonymous connect —
# exactly what this asserts against.
run_test_show "ADR-11" "mosquitto: go-auth enforces auth (anonymous connect refused)" \
  'docker exec "$(ctr_of ga_mosquitto)" sh -c "mosquitto_sub -h 127.0.0.1 -t adr11probe -C 1 -W 2 2>&1" | grep -q "not authorised"' 

# influxdb: the daemon answers its own ping (204), locally.
run_test_show "ADR-12" "influxdb: /ping answers inside the container" \
  'docker exec "$(ctr_of ga_influxdbv1)" sh -c "curl -s -o /dev/null -w %{http_code} http://127.0.0.1:8086/ping" 2>/dev/null | grep -qE "^(200|204)$"'

# the two Python add-ons: pandas 3.0 must IMPORT at runtime on the device —
# the one thing the build pipeline could not prove (import-only evidence).
run_test_show "ADR-13" "ga_default_addon: pandas imports at runtime (3.x major bump)" \
  'docker exec "$(ctr_of ga_default_addon)" python3 -c "import pandas" 2>/dev/null'
run_test_show "ADR-14" "ga_hmvapp_addon: pandas + sklearn import at runtime" \
  'docker exec "$(ctr_of ga_hmvapp_addon)" python3 -c "import pandas, sklearn" 2>/dev/null'

# hardware-control: Node 24 actually executes on this armv7 (qemu could not
# prove this — the device is the first place the JIT truly runs for us).
run_test_show "ADR-15" "hardware-control: node executes (v24 on real armv7)" \
  'docker exec "$(ctr_of ga_ihosthardwarecontrol)" node --version 2>/dev/null | grep -qE "^v[0-9]+"'

# ga_manager: its worker loop is alive (the process, not just the container).
run_test_show "ADR-16" "ga_manager: python worker process alive" \
  'docker exec "$(ctr_of ga_manager)" sh -c "pgrep -f python3 >/dev/null" 2>/dev/null'

# --- restart-loop tripwire -------------------------------------------------
# "Up 2 seconds" forever is a crash loop that up-ness alone cannot see.
run_test_show "ADR-20" "no addon container restarted in the last check (RestartCount==0)" \
  'for c in $(docker ps --format "{{.Names}}" | grep "^addon_"); do
     rc=$(docker inspect "$c" --format "{{.RestartCount}}" 2>/dev/null || echo 1)
     [ "${rc:-1}" -eq 0 ] || exit 1
   done'

suite_end
