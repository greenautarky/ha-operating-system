#!/bin/sh
# Heating — does the device show the OUTCOMES ADR-0021 decided, measured on the
# device itself (Core's state machine, the z2m log, the add-on logs)?
#
# ADR-0021 (ga-ihost-docs, number reserved 2026-09-03) — heating responsibilities:
#   * control AND valve calibration live in the Home Assistant custom component
#     ga_heating (one room entity per area with a TRV);
#   * the add-ons (ga_hmvapp_addon, ga_default_addon) are DATA PRODUCERS — they
#     read the valves and write InfluxDB rows, they do not drive the valves;
#   * exactly ONE sender on each valve.
#
# Every test here asks the device for an OUTCOME, never for a version string or a
# "started" container (global rule 66: a started container can be crash-looping
# behind that green). What was measured, and where it was red:
#   HEAT-02  K31 rc22, 2026-09-03: ga_hmvapp_addon 1.7.1 produced 22 messages per
#            valve on zigbee2mqtt/<ieee>/set in 8 minutes ("Published state
#            request to zigbee2mqtt/<ieee>/set" every ~20 s) — two senders on
#            every valve, the exact state ADR-0021 forbids. Threshold: <= 2 per
#            valve per 10 min (ga_heating's own tick + one resident change).
#   HEAT-04  2026-08-27 defect class (ga-heating #27, released as 0.2.1): the
#            resident's mode choice never reached the state machine — the room
#            entity showed the mode, the store never held it, and a restart lost
#            it. The discriminator is auto<->heat, never via off (a room whose
#            valves are all off answers `off` without any decision on record).
#   HEAT-03  the ga_heating calibration release (branch
#            feat/valve-calibration-in-ga_heating, in development 2026-09-03) is
#            expected to expose `calibration: {<valve>: {offset, written_at}}` on
#            the room entity. Until it ships this test is RED on every device —
#            deliberately: it is the "not yet delivered" line, not a flake.
#   HEAT-05  ga_hmvapp_addon 1.7.1 prints only the TOPIC of its publishes, not the
#            payload, so a setpoint write would be invisible to a log grep; the
#            test therefore also counts every `/set` publish it sees and reports
#            the coverage (rule 9: a grep over zero lines proves nothing).
#
# Run on a PROVISIONED, COMMISSIONED device (paired TRVs, areas assigned). On a
# device without a single TRV every test SKIPs with that reason — an
# uncommissioned device has no heating outcome to assert.
#
# Host tools used: docker, jq (BR2_PACKAGE_JQ=y on ihost), grep, sort, uniq.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

# The other device suites run under plain BusyBox sh without -u/pipefail; -u is
# safe here (every variable is initialised), pipefail is enabled only where the
# shell has it (BusyBox ash does; dash on a laptop does not).
set -u
(set -o pipefail 2>/dev/null) && set -o pipefail

suite_start "Heating (ADR-0021 outcomes: ga_heating owns control + calibration, one sender per valve)"

HA_DIR="${GA_HEAT_HA_DIR:-/mnt/data/supervisor/homeassistant}"   # override only for fixture runs
ENTITY_REG="$HA_DIR/.storage/core.entity_registry"
DEVICE_REG="$HA_DIR/.storage/core.device_registry"
HEATING_STORE="$HA_DIR/.storage/ga_heating"
STATES="/tmp/ga-heat-states.json"      # climate.* + number.* only, a few KB
SET_COUNTS="/tmp/ga-heat-set-counts.txt"
SET_WINDOW="10m"
SET_MAX_PER_VALVE=2

# Supervisor names add-on containers addon_<hash>_<slug>.
ctr_of() { docker ps --format '{{.Names}}' 2>/dev/null | grep -E "^addon_.*_$1\$" | head -1; }

# ---------------------------------------------------------------------------
# Core's view, fetched ONCE through the ga_manager add-on (homeassistant_api:
# true, so it holds a SUPERVISOR_TOKEN). The single quotes are deliberate: the
# token must expand INSIDE the container, never on the host. Reduced to the
# two domains this suite reads so the file stays small on the 15 MB /tmp zram.
# ---------------------------------------------------------------------------
: > "$STATES"
GM="$(ctr_of ga_manager)"
if [ -n "$GM" ]; then
  docker exec "$GM" sh -c \
    'curl -fsS -m 20 -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/api/states' 2>/dev/null \
    | jq -c '[ .[] | select(.entity_id | test("^(climate|number)\\.")) ]' > "$STATES" 2>/dev/null \
    || : > "$STATES"
fi

# Every assertion below reads Core's state; without it the suite would be
# asserting on an empty file. FAIL, not SKIP: a device whose Core cannot be
# asked has no provable heating outcome, and hiding that is the failure mode
# this suite exists for (cf. ha_config_applied HCA-02).
run_test_show "HEAT-00" "Core /api/states readable via ga_manager (jq present, non-empty climate/number list)" \
  'command -v jq >/dev/null || { echo "jq missing on host"; exit 1; }
   [ -n "$GM" ] || { echo "ga_manager container not running"; exit 1; }
   n=$(jq "length" "$STATES" 2>/dev/null || echo 0)
   [ "${n:-0}" -gt 0 ] || { echo "no climate/number entity in Core (fetch failed or nothing paired)"; exit 1; }
   echo "$n climate/number entities"'

# --- the TRVs and their areas, from the REGISTRY (states carry no area) -----
# A zigbee2mqtt TRV is climate.0x<ieee> on the mqtt platform. Its area is the
# entity's own area_id, else its device's — the same resolution ga_heating uses
# (climate.py area_of). Output: "<area_id> <entity_id>" per TRV that HAS an area.
trv_areas() {
  [ -s "$ENTITY_REG" ] && [ -s "$DEVICE_REG" ] || return 0
  jq -r --slurpfile dev "$DEVICE_REG" '
    ($dev[0].data.devices | map({key: .id, value: .area_id}) | from_entries) as $darea
    | .data.entities[]
    | select(.entity_id | test("^climate\\.0x[0-9a-f]+$"))
    | select(.platform == "mqtt")
    | (.area_id // $darea[.device_id // ""]) as $area
    | select($area != null)
    | "\($area) \(.entity_id)"' "$ENTITY_REG" 2>/dev/null
}
TRV_COUNT=$(trv_areas | wc -l | tr -d ' ')

# --- room entities: ga_heating platform, one per area ------------------------
# climate.py: unique_id = "ga_heating_<area_id>", has_entity_name = False, so
# the entity_id is the slug of the AREA NAME (climate.wohnzimmer), not the
# area_id. Resolve through the registry rather than guessing the slug.
room_entity_for_area() {
  jq -r --arg uid "ga_heating_$1" '
    .data.entities[] | select(.platform == "ga_heating" and .unique_id == $uid) | .entity_id' \
    "$ENTITY_REG" 2>/dev/null | head -1
}
# "<entity_id>" of every ga_heating room entity present in Core, with state.
room_entities() {
  jq -r '.[] | select(.entity_id | startswith("climate.")) | select(.entity_id | test("^climate\\.0x[0-9a-f]+$") | not) | select(.attributes.valves != null) | .entity_id' "$STATES" 2>/dev/null
}
state_of()  { jq -r --arg e "$1" '.[] | select(.entity_id == $e) | .state' "$STATES" 2>/dev/null | head -1; }
attr_of()   { jq -r --arg e "$1" --arg a "$2" '.[] | select(.entity_id == $e) | .attributes[$a] // empty' "$STATES" 2>/dev/null | head -1; }
attr_json() { jq -c --arg e "$1" --arg a "$2" '.[] | select(.entity_id == $e) | .attributes[$a] // empty' "$STATES" 2>/dev/null | head -1; }

# =========================================================================
# HEAT-01 — a ga_heating room entity exists for every area with a TRV
# =========================================================================
# Red proof (K0, 2026-08-18, ga-heating fix/room-entity-area): the room entity
# existed and worked but sat in no area — every consumer that resolves "which
# room" through the registry saw nothing. This asserts the entity is there AND
# reachable in Core's state machine (state not unavailable), per area.
heat01() {
  _missing=""; _ok=0; _areas=0
  for _area in $(trv_areas | cut -d' ' -f1 | sort -u); do
    _areas=$((_areas+1))
    _room=$(room_entity_for_area "$_area")
    _st=""
    [ -n "$_room" ] && _st=$(state_of "$_room")
    case "$_st" in
      ""|unavailable|unknown) _missing="$_missing $_area(${_room:-no-entity}:${_st:-absent})" ;;
      *) _ok=$((_ok+1)) ;;
    esac
  done
  if [ -n "$_missing" ]; then
    echo "$_ok/$_areas areas have a live room entity; missing:$_missing"; return 1
  fi
  echo "$_ok/$_areas areas with a TRV have a live ga_heating room entity ($TRV_COUNT TRVs)"
}
if [ "$TRV_COUNT" -eq 0 ]; then
  skip_test "HEAT-01" "ga_heating room entity per area with a TRV" "no zigbee2mqtt TRV (climate.0x…) with an area in the entity registry"
else
  run_test_show "HEAT-01" "ga_heating room entity per area with a TRV (registry: platform ga_heating, unique_id ga_heating_<area>)" 'heat01'
fi

# =========================================================================
# HEAT-02 — one sender on the valves: <= 2 messages per valve on
#           zigbee2mqtt/<ieee>/set within the last 10 minutes
# =========================================================================
# Red proof: K31 rc22, 2026-09-03 — 22 per valve in 8 min from
# ga_hmvapp_addon 1.7.1 (a "state request" to /set every ~20 s), with
# ga_heating driving the same valves. Measured with exactly this pipeline:
#   docker logs --since 10m <z2m> 2>&1 | grep -oE "zigbee2mqtt/0x[0-9a-f]+/set" | sort | uniq -c
heat02() {
  _z2m=$(ctr_of ga_zigbee2mqtt)
  docker logs --since "$SET_WINDOW" "$_z2m" 2>&1 \
    | grep -oE "zigbee2mqtt/0x[0-9a-f]+/set" | sort | uniq -c > "$SET_COUNTS" 2>/dev/null
  if [ ! -s "$SET_COUNTS" ]; then
    echo "0 messages on any zigbee2mqtt/<ieee>/set in the last $SET_WINDOW"; return 0
  fi
  _worst=0; _summary=""
  while read -r _n _topic; do
    _ieee=${_topic#zigbee2mqtt/}; _ieee=${_ieee%/set}
    _summary="$_summary $_ieee=$_n"
    [ "$_n" -gt "$_worst" ] && _worst=$_n
  done < "$SET_COUNTS"
  echo "/set per valve in $SET_WINDOW:$_summary (max allowed $SET_MAX_PER_VALVE)"
  [ "$_worst" -le "$SET_MAX_PER_VALVE" ]
}
if [ -z "$(ctr_of ga_zigbee2mqtt)" ]; then
  skip_test "HEAT-02" "one sender per valve (<= $SET_MAX_PER_VALVE /set per valve per $SET_WINDOW)" "ga_zigbee2mqtt container absent — no valve traffic to inspect"
else
  run_test_show "HEAT-02" "one sender per valve (<= $SET_MAX_PER_VALVE messages on zigbee2mqtt/<ieee>/set per valve in $SET_WINDOW)" 'heat02'
fi

# =========================================================================
# HEAT-03 — calibration is owned by ga_heating
# =========================================================================
# For every room whose temperature comes from a DEDICATED room sensor
# (attribute temperature_source != "valve"; climate.py exposes the sensor's
# entity_id there), the room entity must carry the calibration the component
# wrote: `calibration: {<valve>: {offset, written_at}}` (attribute name and
# shape as agreed for feat/valve-calibration-in-ga_heating — ASSUMED, the
# branch had no code yet on 2026-09-03; adjust here if the release differs).
# And the valve's own number.<ieee>_local_temperature_calibration must hold a
# value: `unknown` means nobody ever wrote an offset (measured on K0
# 2026-08-18: rooms reporting temperature_source: valve while a sensor existed).
# Missing attribute = FAIL "ga_heating < calibration release — attribute
# absent": red until the release ships, by design.
heat03() {
  _fail=""; _ok=0; _rooms=0
  for _room in $(room_entities); do
    _src=$(attr_of "$_room" temperature_source)
    [ -n "$_src" ] && [ "$_src" != "valve" ] || continue
    _rooms=$((_rooms+1)); _roomfail=0
    _cal=$(attr_json "$_room" calibration)
    if [ -z "$_cal" ] || [ "$_cal" = "null" ]; then
      _fail="$_fail $_room: ga_heating < calibration release — attribute absent;"; continue
    fi
    for _valve in $(attr_json "$_room" valves | jq -r '.[]?' 2>/dev/null); do
      _entry=$(printf '%s' "$_cal" | jq -c --arg v "$_valve" '.[$v] // empty' 2>/dev/null)
      if [ -z "$_entry" ] || ! printf '%s' "$_entry" | jq -e 'has("offset") and has("written_at")' >/dev/null 2>&1; then
        _fail="$_fail $_room: no calibration{offset,written_at} for $_valve;"; _roomfail=1; continue
      fi
      _ieee=${_valve#climate.}
      _num=$(state_of "number.${_ieee}_local_temperature_calibration")
      case "$_num" in
        ""|unknown|unavailable) _fail="$_fail $_room: number.${_ieee}_local_temperature_calibration is ${_num:-absent};"; _roomfail=1 ;;
      esac
    done
    [ "$_roomfail" -eq 0 ] && _ok=$((_ok+1))
  done
  if [ -n "$_fail" ]; then echo "$_ok/$_rooms rooms with a dedicated sensor OK;$_fail"; return 1; fi
  echo "$_ok/$_rooms rooms with a dedicated sensor carry ga_heating calibration and a written valve offset"
}
ROOMS_WITH_SENSOR=0
for _r in $(room_entities); do
  _s=$(attr_of "$_r" temperature_source)
  [ -n "$_s" ] && [ "$_s" != "valve" ] && ROOMS_WITH_SENSOR=$((ROOMS_WITH_SENSOR+1))
done
if [ "$TRV_COUNT" -eq 0 ]; then
  skip_test "HEAT-03" "calibration owned by ga_heating (room attribute + valve offset written)" "no TRV paired"
elif [ "$ROOMS_WITH_SENSOR" -eq 0 ]; then
  skip_test "HEAT-03" "calibration owned by ga_heating (room attribute + valve offset written)" "no room entity with a dedicated room sensor (temperature_source: valve everywhere)"
else
  run_test_show "HEAT-03" "calibration owned by ga_heating: calibration{offset,written_at} per valve on the room entity, number.<ieee>_local_temperature_calibration not unknown" 'heat03'
fi

# =========================================================================
# HEAT-04 — the room's mode reaches the state machine
# =========================================================================
# Red proof: 2026-08-27 (ga-heating #27) — climate.<room> showed `heat`, the
# store held nothing, the plan kept running. Store = HA Store("ga_heating"),
# file .storage/ga_heating, {"data": {"room_modes": {<entity_id>: <mode>}}}.
# The first room entity offering `auto` is compared: stored decision == live
# state. No store, or no decision for that room, = SKIP (nothing to compare
# — say so rather than pass).
heat04() {
  _room="$1"
  _live=$(state_of "$_room")
  _stored=$(jq -r --arg e "$_room" '.data.room_modes[$e] // empty' "$HEATING_STORE" 2>/dev/null)
  echo "$_room: live=$_live stored=${_stored:-<none>}"
  [ -n "$_stored" ] && [ "$_stored" = "$_live" ]
}
ROOM_AUTO=""
for _r in $(room_entities); do
  if attr_json "$_r" hvac_modes | jq -e 'index("auto") != null' >/dev/null 2>&1; then ROOM_AUTO="$_r"; break; fi
done
if [ "$TRV_COUNT" -eq 0 ]; then
  skip_test "HEAT-04" "room mode reaches the state machine (.storage/ga_heating room_modes == live state)" "no TRV paired"
elif [ -z "$ROOM_AUTO" ]; then
  skip_test "HEAT-04" "room mode reaches the state machine (.storage/ga_heating room_modes == live state)" "no room entity with hvac_mode auto in Core"
elif [ ! -s "$HEATING_STORE" ]; then
  skip_test "HEAT-04" "room mode reaches the state machine (.storage/ga_heating room_modes == live state)" "$HEATING_STORE does not exist yet — no decision recorded"
elif [ -z "$(jq -r --arg e "$ROOM_AUTO" '.data.room_modes[$e] // empty' "$HEATING_STORE" 2>/dev/null)" ]; then
  skip_test "HEAT-04" "room mode reaches the state machine (.storage/ga_heating room_modes == live state)" "no decision recorded for $ROOM_AUTO in room_modes (live=$(state_of "$ROOM_AUTO"))"
else
  run_test_show "HEAT-04" "room mode reaches the state machine (.storage/ga_heating room_modes[$ROOM_AUTO] == live state)" "heat04 $ROOM_AUTO"
fi

# =========================================================================
# HEAT-05 — no add-on writes setpoints or modes
# =========================================================================
# A WRITE is a publish to zigbee2mqtt/<ieee>/set; the same keys also appear in
# every state echo the add-ons log ("Received message from zigbee2mqtt/<ieee>:
# {...occupied_heating_setpoint...}"), so the discriminator is a /set topic AND
# one of the keys on the same log line. Coverage is reported (lines inspected,
# /set publishes seen) because ga_hmvapp_addon 1.7.1 prints the topic without
# the payload — a grep that sees no /set line at all has proven nothing.
# hmvapp absent = PASS with that message: ADR-0021 allows the rework to remove it.
heat05() {
  _msg=""; _bad=0
  for _slug in ga_hmvapp_addon ga_default_addon; do
    _c=$(ctr_of "$_slug")
    if [ -z "$_c" ]; then _msg="$_msg $_slug: container absent (allowed — ADR-0021 rework may remove it);"; continue; fi
    _log=$(docker logs --since "$SET_WINDOW" "$_c" 2>&1)
    _lines=$(printf '%s\n' "$_log" | grep -c . )
    _sets=$(printf '%s\n' "$_log" | grep -cE "zigbee2mqtt/0x[0-9a-f]+/set")
    _writes=$(printf '%s\n' "$_log" | grep -E "zigbee2mqtt/0x[0-9a-f]+/set" | grep -cE "occupied_heating_setpoint|system_mode")
    _msg="$_msg $_slug: $_lines lines, $_sets /set publishes, $_writes setpoint/mode writes;"
    [ "$_writes" -eq 0 ] || _bad=1
  done
  echo "last $SET_WINDOW:$_msg"
  [ "$_bad" -eq 0 ]
}
run_test_show "HEAT-05" "no add-on writes occupied_heating_setpoint/system_mode to a valve (hmvapp + default_addon logs, $SET_WINDOW)" 'heat05'

rm -f "$STATES" "$SET_COUNTS"
suite_end
