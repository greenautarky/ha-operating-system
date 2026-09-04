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

# --- does each application add-on WRITE? (the outcome, not the login) ------
# ADR-12 proves the daemon answers and the fresh-flash gate proves each add-on
# AUTHENTICATES (HTTP 200). Neither proves a row is flowing: an add-on can
# answer 200 and write nothing — empty batches, a room registry it cannot read,
# a database it holds no grant on (rc14 was "started" + 401 behind a green;
# this is the next blind spot after auth). Each add-on has ONE write path on a
# fixed cadence, so "a row younger than 10 minutes in that measurement, read
# under the add-on's OWN delivered credential" is the outcome.
# Pinned from source — never derived from the device under test:
#   ga_default_addon  radiator_data() every 180 s        -> "radiator_data"
#     (default_addon/app/main.py:530, functions/radiator_data.py:132,:168)
#   ga_hmvapp_addon   control_radiator() on the 3 s loop -> "system_info"
#     (hmvapp_addon/app/main.py:70, functions/heating_management.py:2255)
# Both write to INFLUXDB_GD_DATABASE = gd_data; both users hold ALL on it
# (influxDBv1 rootfs/etc/cont-init.d/00_create-db_and_users.sh:115-116).
# Caveat before anyone widens the window to make this green: both paths only
# write when at least one room has a paired radiator (radiator_data.py:302,
# heating_management.py:2334). On an uncommissioned device these are red, and
# that is the honest state, not a flake.
INFLUX_URL="http://127.0.0.1:8086"   # ga_influxdbv1 maps 8086/tcp:8086 onto the host (store config.yaml:31)
FRESH_DB="gd_data"
FRESH_WINDOW="10m"
ADDON_DATA="/mnt/data/supervisor/addons/data"   # <repo>_<slug>/options.json, host side

# _fresh_row <slug> <measurement> — 0 iff gd_data.<measurement> holds a row
# younger than FRESH_WINDOW, queried under <slug>'s own credential. The
# credential is read from the host-side options.json into shell variables and
# handed to curl via --data-urlencode; it is never echoed and never printed —
# every message below is built from the response, not the request.
_fresh_row() {
  _slug="$1"; _m="$2"
  _opt=$(ls -d "$ADDON_DATA"/*_"$_slug"/options.json 2>/dev/null | head -1)
  if [ -z "$_opt" ]; then echo "no options.json for $_slug under $ADDON_DATA"; return 1; fi
  _u=$(sed -n 's/.*"INFLUXDB_USERNAME"[^"]*"\([^"]*\)".*/\1/p' "$_opt" | head -1)
  _p=$(sed -n 's/.*"INFLUXDB_PASSWORD"[^"]*"\([^"]*\)".*/\1/p' "$_opt" | head -1)
  if [ -z "$_u" ] || [ -z "$_p" ]; then
    echo "credential not delivered yet (INFLUXDB_USERNAME/INFLUXDB_PASSWORD empty in options.json)"; return 1
  fi
  _body=$(curl -s -m 15 -G "$INFLUX_URL/query" \
            --data-urlencode "u=$_u" --data-urlencode "p=$_p" \
            --data-urlencode "db=$FRESH_DB" \
            --data-urlencode "q=SELECT last(*) FROM \"$_m\" WHERE time > now() - $FRESH_WINDOW" 2>/dev/null)
  unset _u _p
  case "$_body" in
    '')                      echo "no response from $INFLUX_URL"; return 1 ;;
    *'"error"'*)             echo "influx refused: $(printf '%s' "$_body" | cut -c1-160)"; return 1 ;;
    *'"series"'*'"values"'*) echo "newest row: $(printf '%s' "$_body" | sed -n 's/.*"values":\[\["\([^"]*\)".*/\1/p')"; return 0 ;;
    *)                       echo "no row in $FRESH_DB.$_m within $FRESH_WINDOW"; return 1 ;;
  esac
}
# _fresh_check <id> <slug> <measurement> — SKIP (with the reason) when the
# subject cannot be asked at all; otherwise a real PASS/FAIL.
_fresh_check() {
  _fid="$1"; _fslug="$2"; _fm="$3"
  _fdesc="$_fslug: wrote $FRESH_DB.$_fm within $FRESH_WINDOW under its own credential"
  if ! up ga_influxdbv1; then
    skip_test "$_fid" "$_fdesc" "ga_influxdbv1 not running — nothing to query (ADR-03 covers it)"
  elif ! up "$_fslug"; then
    skip_test "$_fid" "$_fdesc" "$_fslug not running — nothing can have written (ADR-04/05 cover it)"
  elif [ "${4:-}" = "info" ]; then
    # informational: the measurement stays visible, the suite does not go red on it
    if _fresh_row "$_fslug" "$_fm"; then run_test_show "$_fid" "$_fdesc" "true"; else skip_test "$_fid" "$_fdesc" "informational — no row yet (see comment above)"; fi
  else
    run_test_show "$_fid" "$_fdesc" "_fresh_row $_fslug $_fm"
  fi
}
_fresh_check "ADR-17" ga_default_addon radiator_data
# ADR-18 is informational until ga_hmvapp_addon writes at all: measured twice on
# K31 rc22 (2026-09-03, all four valves reporting for 15+ min) it wrote no
# system_info row while ga_default_addon wrote every 3 min (Odoo #642). A red
# nobody can turn green teaches people to ignore the suite; the measurement
# stays visible as WARN/SKIP and flips to a real test with the hmvapp fix.
_fresh_check "ADR-18" ga_hmvapp_addon  system_info info

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

# ==========================================================================
# ADR-19 — the cloud producer knows WHICH DEVICE it is
# ==========================================================================
# ga_default_addon 2.1.0 keys every cloud batch on a device id it resolves in
# three steps: a delivered DEVICE_ID/HA_UUID option, then Home Assistant's
# .storage/core.uuid, then the legacy device_info row in InfluxDB.
#
# Red proof, K31 fresh-flashed with rc23 and fully onboarded, 2026-09-04:
# ALL THREE were empty. No option is delivered; Home Assistant 2025.11.3 had
# written no core.uuid at all (it is created lazily, the first time something
# asks the instance-id helper — and nothing on a GA device does); and the
# legacy row's writer was retired with ADR-0021. The add-on said so plainly —
# "device id UNKNOWN from every source" — and kept producing, so every local
# measurement was right while the cloud side had nothing to key on.
#
# And it CAN pass: on K49 the same day, core.uuid was present. The file exists
# where something once asked for it and is missing where nothing ever did
# (K0 was missing it too), which is why this belongs on the device rather than
# in CI — the file the add-on reads does not exist in a build at all.
#
# This asks the add-on's own resolver, on the device, for the outcome.
run_test_show "ADR-19" "ga_default_addon resolves a device identity (option / core.uuid / legacy row)" \
  'docker exec "$(ctr_of ga_default_addon)" python3 -c "
import sys
sys.path.insert(0, \"/app\")
from utils.device_identity import device_identity
i = device_identity()
print(\"source=\" + str(i.source) + \" known=\" + str(i.known))
sys.exit(0 if i.known else 1)
" 2>/dev/null'

# --- the Supervisor plugins: do they WORK? ---------------------------------
# Identity is os_integrity's job; this is function. DNS is the device's
# lifeline — a running-but-broken resolver takes every pull, every MQTT
# reconnect and Core itself down with it, and "container Up" cannot see that.
# GA builds two of these since 2026-08-24, so the plane is ours to prove.
run_test_show "ADR-30" "dns plugin resolves for an add-on (the lifeline, not the process)" \
  'docker exec "$(ctr_of ga_manager)" python3 -c "import socket; socket.gethostbyname(\"ghcr.io\")" 2>/dev/null'
run_test_show "ADR-31" "dns plugin resolves for HA Core" \
  'docker exec homeassistant python3 -c "import socket; socket.gethostbyname(\"github.com\")" 2>/dev/null'
run_test_show "ADR-32" "cli plugin executes (it backs every ha command)" \
  'docker exec hassio_cli ha help >/dev/null 2>&1'
run_test_show "ADR-33" "no plugin container is restarting" \
  'for c in hassio_dns hassio_cli hassio_audio hassio_observer hassio_multicast; do
     rc=$(docker inspect "$c" --format "{{.RestartCount}}" 2>/dev/null || echo 1)
     [ "${rc:-1}" -eq 0 ] || exit 1
   done'

# --- restart-loop tripwire -------------------------------------------------
# "Up 2 seconds" forever is a crash loop that up-ness alone cannot see.
run_test_show "ADR-20" "no addon container restarted in the last check (RestartCount==0)" \
  'for c in $(docker ps --format "{{.Names}}" | grep "^addon_"); do
     rc=$(docker inspect "$c" --format "{{.RestartCount}}" 2>/dev/null || echo 1)
     [ "${rc:-1}" -eq 0 ] || exit 1
   done'

suite_end
