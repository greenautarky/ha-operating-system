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
#   HEAT-03  ga_heating 0.4.0 (shipped 2026-09-03, shape confirmed on K31) exposes
#            `calibration: {<valve>: {offset, written_at, source, reason}}` on the
#            room entity; `source` is "hmvapp" or "default" (null before the
#            first write). A device still on < 0.4.0 is RED here — deliberately:
#            it is the "not yet delivered" line, not a flake.
#   HEAT-05  ga_hmvapp_addon 1.7.1 prints only the TOPIC of its publishes, not the
#            payload, so a setpoint write would be invisible to a log grep; the
#            test therefore also counts every `/set` publish it sees and reports
#            the coverage (rule 9: a grep over zero lines proves nothing).
#   HEAT-06/07/08  the heating decision contract v1 (ADR-0021 §3): the closed
#            decision engine (ga_hmvapp_addon >= 2.0.0) publishes ONE
#            sensor.hm_<ieee>_desired_offset per valve in a room with a dedicated
#            sensor (contract=1, valid_until), writes one gd_data.hm_liveness row
#            per room per 60 s cycle, and holds ONE long-lived MQTT client
#            (ga_hmvapp_decisions). Red-proof state: hmvapp 1.7.1 opened a NEW
#            broker connection for every read and write — several per valve per
#            3-second cycle (K31 rc22, 2026-09-03) — and wrote no liveness at all.
#
# Run on a PROVISIONED, COMMISSIONED device (paired TRVs, areas assigned). On a
# device without a single TRV every test SKIPs with that reason — an
# uncommissioned device has no heating outcome to assert.
#
# Host tools used: docker, jq (BR2_PACKAGE_JQ=y on ihost — built WITHOUT oniguruma:
# no test()/match()/sub(); use startswith/endswith/contains only — K31 rc22, 2026-09-03),
# grep, sed, sort, uniq, cut, date (BusyBox: no `date -d`, so ISO-8601 UTC
# stamps are compared as STRINGS on their first 19 characters), curl (HEAT-07;
# SKIP with the reason when absent).
#
# Fixture run (no device): selftest.sh next to this file drives THIS script over
# fixtures/ with a docker/curl shim; the overrides it uses are GA_HEAT_HA_DIR,
# GA_HEAT_ADDON_DATA and GA_HEAT_TMP. Nothing else is fixture-aware.
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
ADDON_DATA="${GA_HEAT_ADDON_DATA:-/mnt/data/supervisor/addons/data}"   # <repo>_<slug>/options.json, host side
TMP_DIR="${GA_HEAT_TMP:-/tmp}"
STATES="$TMP_DIR/ga-heat-states.json"  # climate.* + number.* + sensor.hm_* only, a few KB
SET_COUNTS="$TMP_DIR/ga-heat-set-counts.txt"
SET_WINDOW="10m"
SET_MAX_PER_VALVE=2
ENGINE_SLUG="ga_hmvapp_addon"          # the decision engine, >= 2.0.0 speaks contract v1
ENGINE_MIN_UP_MIN=15                   # HEAT-06: younger than this = no cycle has necessarily run
ENGINE_CLIENT_PREFIX="ga_hmvapp"       # its one MQTT client id is ga_hmvapp_decisions
MQTT_CONNECT_MAX=10                    # HEAT-08: connects allowed per SET_WINDOW (reconnects on broker restart only)
LIVENESS_WINDOW="5m"                   # HEAT-07: one row per room per 60 s cycle
INFLUX_URL="http://127.0.0.1:8086"     # ga_influxdbv1 maps 8086/tcp:8086 onto the host (store config.yaml:31)
INFLUX_DB="gd_data"

# Supervisor names add-on containers addon_<hash>_<slug>.
ctr_of() { docker ps --format '{{.Names}}' 2>/dev/null | grep -E "^addon_.*_$1\$" | head -1; }
# "Up 3 minutes" / "Up About a minute" / "Up 2 hours" for a container name.
status_of() { docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep "^$1 " | head -1 | cut -d' ' -f2-; }

# ---------------------------------------------------------------------------
# Core's view, fetched ONCE through the ga_manager add-on (homeassistant_api:
# true, so it holds a SUPERVISOR_TOKEN). The single quotes are deliberate: the
# token must expand INSIDE the container, never on the host. Reduced to the
# three entity families this suite reads (room + valve climates, the valves'
# calibration numbers, the engine's sensor.hm_* decisions) so the file stays
# small on the 15 MB /tmp zram.
# ---------------------------------------------------------------------------
: > "$STATES"
GM="$(ctr_of ga_manager)"
if [ -n "$GM" ]; then
  docker exec "$GM" sh -c \
    'curl -fsS -m 20 -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/api/states' 2>/dev/null \
    | jq -c '[ .[] | select(.entity_id | startswith("climate.") or startswith("number.") or startswith("sensor.hm_")) ]' > "$STATES" 2>/dev/null \
    || : > "$STATES"
fi

# Every assertion below reads Core's state; without it the suite would be
# asserting on an empty file. FAIL, not SKIP: a device whose Core cannot be
# asked has no provable heating outcome, and hiding that is the failure mode
# this suite exists for (cf. ha_config_applied HCA-02).
run_test_show "HEAT-00" "Core /api/states readable via ga_manager (jq present, non-empty climate/number/sensor.hm_ list)" \
  'command -v jq >/dev/null || { echo "jq missing on host"; exit 1; }
   [ -n "$GM" ] || { echo "ga_manager container not running"; exit 1; }
   n=$(jq "length" "$STATES" 2>/dev/null || echo 0)
   [ "${n:-0}" -gt 0 ] || { echo "no climate/number/sensor.hm_ entity in Core (fetch failed or nothing paired)"; exit 1; }
   echo "$n climate/number/sensor.hm_ entities"'

# --- the TRVs and their areas, from the REGISTRY (states carry no area) -----
# A zigbee2mqtt TRV is climate.0x<ieee> on the mqtt platform. Its area is the
# entity's own area_id, else its device's — the same resolution ga_heating uses
# (climate.py area_of). Output: "<area_id> <entity_id>" per TRV that HAS an area.
trv_areas() {
  [ -s "$ENTITY_REG" ] && [ -s "$DEVICE_REG" ] || return 0
  jq -r --slurpfile dev "$DEVICE_REG" '
    ($dev[0].data.devices | map({key: .id, value: .area_id}) | from_entries) as $darea
    | .data.entities[]
    | select(.entity_id | startswith("climate.0x"))
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
  jq -r '.[] | select(.entity_id | startswith("climate.")) | select(.entity_id | startswith("climate.0x") | not) | select(.attributes.valves != null) | .entity_id' "$STATES" 2>/dev/null
}
# area_id of a ga_heating room entity (the inverse of room_entity_for_area).
area_of_room() {
  jq -r --arg e "$1" '
    .data.entities[] | select(.platform == "ga_heating" and .entity_id == $e) | .unique_id | ltrimstr("ga_heating_")' \
    "$ENTITY_REG" 2>/dev/null | head -1
}
# room entities whose temperature comes from a DEDICATED sensor (never "valve").
rooms_with_sensor() {
  for _rws in $(room_entities); do
    _srcws=$(attr_of "$_rws" temperature_source)
    [ -n "$_srcws" ] && [ "$_srcws" != "valve" ] && echo "$_rws"
  done
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
# wrote: `calibration: {<valve>: {offset, written_at, source, reason}}` —
# ga_heating 0.4.0, shipped 2026-09-03, shape confirmed on K31. `source` is
# the decision provenance ("hmvapp" from the engine, "default" from the
# component's own fallback; null before the first write) — REQUIRED as a key,
# because without it nobody can tell whose offset sits on the valve, which is
# the ADR-0021 §3 question. Rooms on temperature_source: valve are never
# calibrated and are not inspected here.
# And the valve's own number.<ieee>_local_temperature_calibration must hold a
# value: `unknown` means nobody ever wrote an offset (measured on K0
# 2026-08-18: rooms reporting temperature_source: valve while a sensor existed).
# Missing attribute = FAIL "ga_heating < 0.4.0 — attribute absent": red on a
# device still carrying the older component, by design.
heat03() {
  _fail=""; _ok=0; _rooms=0
  for _room in $(rooms_with_sensor); do
    _rooms=$((_rooms+1)); _roomfail=0
    _cal=$(attr_json "$_room" calibration)
    if [ -z "$_cal" ] || [ "$_cal" = "null" ]; then
      _fail="$_fail $_room: ga_heating < 0.4.0 — calibration attribute absent;"; continue
    fi
    for _valve in $(attr_json "$_room" valves | jq -r '.[]?' 2>/dev/null); do
      _entry=$(printf '%s' "$_cal" | jq -c --arg v "$_valve" '.[$v] // empty' 2>/dev/null)
      if [ -z "$_entry" ] || ! printf '%s' "$_entry" | jq -e 'has("offset") and has("written_at") and has("source")' >/dev/null 2>&1; then
        _fail="$_fail $_room: no calibration{offset,written_at,source} for $_valve;"; _roomfail=1; continue
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
  echo "$_ok/$_rooms rooms with a dedicated sensor carry ga_heating calibration{offset,written_at,source} and a written valve offset"
}
ROOMS_WITH_SENSOR=$(rooms_with_sensor | wc -l | tr -d ' ')
if [ "$TRV_COUNT" -eq 0 ]; then
  skip_test "HEAT-03" "calibration owned by ga_heating (room attribute + valve offset written)" "no TRV paired"
elif [ "$ROOMS_WITH_SENSOR" -eq 0 ]; then
  skip_test "HEAT-03" "calibration owned by ga_heating (room attribute + valve offset written)" "no room entity with a dedicated room sensor (temperature_source: valve everywhere)"
else
  run_test_show "HEAT-03" "calibration owned by ga_heating: calibration{offset,written_at,source} per valve on the room entity, number.<ieee>_local_temperature_calibration not unknown" 'heat03'
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

# =========================================================================
# HEAT-06 — a decision per valve (heating decision contract v1, ADR-0021 §3)
# =========================================================================
# The engine (ga_hmvapp_addon >= 2.0.0) publishes ONE HA sensor per valve via
# MQTT discovery: sensor.hm_<ieee>_desired_offset, state = desired offset,
# attributes contract (=1), reason, valid_until (ISO-8601 UTC), room,
# model_version, decided_at — only for valves in rooms WITH a dedicated
# sensor (a room on temperature_source: valve is never calibrated, so no
# decision is expected there). ga_heating 0.4.0 is the consumer; a missing,
# non-numeric, wrong-contract or EXPIRED decision means the valve runs on the
# component's fallback, which is exactly what the contract must make visible.
#
# valid_until is compared as a STRING: BusyBox date has no -d, so
# `date -u +%Y-%m-%dT%H:%M:%S` against the first 19 characters of the
# attribute is the whole comparison — correct only because the contract fixes
# the stamp to UTC (a "+02:00" stamp would compare two hours wrong).
#
# Too-young engine = SKIP, not FAIL: the first cycle needs the valves' first
# state echo; `docker ps` Status is the age source ("Up 3 minutes", "Up About
# a minute", "Up 2 hours") — no date arithmetic on the host.
engine_too_young() {
  case "$1" in
    Up\ Less*|Up\ *second*|Up\ About\ a\ minute*) return 0 ;;
    Up\ *minute*) _m=$(printf '%s' "$1" | cut -d' ' -f2); [ "${_m:-0}" -lt "$ENGINE_MIN_UP_MIN" ] 2>/dev/null && return 0 ;;
  esac
  return 1
}
heat06() {
  _now=$(date -u +%Y-%m-%dT%H:%M:%S)
  _fail=""; _ok=0; _n=0
  for _room in $(rooms_with_sensor); do
    for _valve in $(attr_json "$_room" valves | jq -r '.[]?' 2>/dev/null); do
      _n=$((_n+1))
      _ieee=${_valve#climate.}
      _sensor="sensor.hm_${_ieee}_desired_offset"
      _st=$(state_of "$_sensor")
      if [ -z "$_st" ]; then _fail="$_fail $_room/$_ieee: $_sensor absent;"; continue; fi
      if ! jq -en --arg s "$_st" '($s | tonumber) | type == "number"' >/dev/null 2>&1; then
        _fail="$_fail $_room/$_ieee: state '$_st' not numeric;"; continue
      fi
      _contract=$(attr_of "$_sensor" contract)
      if ! jq -en --arg c "$_contract" '($c | tonumber) == 1' >/dev/null 2>&1; then
        _fail="$_fail $_room/$_ieee: contract=${_contract:-absent} (want 1);"; continue
      fi
      _vu=$(attr_of "$_sensor" valid_until | cut -c1-19)
      if [ -z "$_vu" ] || ! jq -en --arg a "$_vu" --arg b "$_now" '$a > $b' >/dev/null 2>&1; then
        _fail="$_fail $_room/$_ieee: valid_until=${_vu:-absent} <= now=${_now}Z;"; continue
      fi
      _ok=$((_ok+1))
    done
  done
  [ "$_n" -gt 0 ] || { echo "0 valves in rooms with a dedicated sensor — nothing inspected"; return 1; }
  if [ -n "$_fail" ]; then echo "$_ok/$_n valves hold a valid contract-1 decision;$_fail"; return 1; fi
  echo "$_ok/$_n valves hold sensor.hm_<ieee>_desired_offset: numeric, contract=1, valid_until > ${_now}Z"
}
ENGINE=$(ctr_of "$ENGINE_SLUG")
ENGINE_STATUS=""
[ -n "$ENGINE" ] && ENGINE_STATUS=$(status_of "$ENGINE")
H06_DESC="a valid decision per valve (sensor.hm_<ieee>_desired_offset numeric, contract=1, valid_until in the future; rooms with a dedicated sensor)"
if [ "$TRV_COUNT" -eq 0 ]; then
  skip_test "HEAT-06" "$H06_DESC" "no TRV paired"
elif [ "$ROOMS_WITH_SENSOR" -eq 0 ]; then
  skip_test "HEAT-06" "$H06_DESC" "no room entity with a dedicated room sensor (temperature_source: valve everywhere)"
elif [ -z "$ENGINE" ]; then
  skip_test "HEAT-06" "$H06_DESC" "decision engine not installed — HEAT-06 needs $ENGINE_SLUG >= 2.0.0"
elif engine_too_young "$ENGINE_STATUS"; then
  skip_test "HEAT-06" "$H06_DESC" "engine up < $ENGINE_MIN_UP_MIN min ($ENGINE_STATUS) — first decision cycle not guaranteed yet"
else
  run_test_show "HEAT-06" "$H06_DESC" 'heat06'
fi

# =========================================================================
# HEAT-07 — engine liveness: one gd_data.hm_liveness row per room per cycle
# =========================================================================
# The engine writes one row per room per 60 s cycle into the LOCAL InfluxDB
# 1.x (add-on ga_influxdbv1, host :8086): measurement hm_liveness, tag
# room (= area id), fields reason (string), decided (0/1). NOT system_info —
# that measurement belongs to the model. A row younger than 5 min per room
# with a dedicated sensor is the outcome; a published decision with no
# liveness row is a stale retained MQTT message, which HEAT-06 alone cannot
# tell from a live engine.
#
# Credential path (same as addons_running ADR-17): the engine's OWN delivered
# credential, read from its host-side options.json into shell variables and
# handed to curl via --data-urlencode — never echoed, never printed; every
# message below is built from the response, not the request.
influx_cred() {
  _opt=""
  for _o in "$ADDON_DATA"/*_"$ENGINE_SLUG"/options.json; do
    [ -e "$_o" ] && { _opt="$_o"; break; }
  done
  [ -n "$_opt" ] || return 1
  _iu=$(sed -n 's/.*"INFLUXDB_USERNAME"[^"]*"\([^"]*\)".*/\1/p' "$_opt" | head -1)
  _ip=$(sed -n 's/.*"INFLUXDB_PASSWORD"[^"]*"\([^"]*\)".*/\1/p' "$_opt" | head -1)
  [ -n "$_iu" ] && [ -n "$_ip" ]
}
heat07() {
  _fail=""; _ok=0; _n=0
  influx_cred || { echo "credential unreadable at query time"; return 1; }
  for _room in $(rooms_with_sensor); do
    _n=$((_n+1))
    _area=$(area_of_room "$_room")
    if [ -z "$_area" ]; then _fail="$_fail $_room: no ga_heating registry entry — area id unknown;"; continue; fi
    _body=$(curl -s -m 15 -G "$INFLUX_URL/query" \
              --data-urlencode "u=$_iu" --data-urlencode "p=$_ip" \
              --data-urlencode "db=$INFLUX_DB" \
              --data-urlencode "q=SELECT LAST(\"decided\") FROM \"hm_liveness\" WHERE \"room\"='$_area' AND time > now() - $LIVENESS_WINDOW" 2>/dev/null)
    case "$_body" in
      '')                      _fail="$_fail $_area: no response from $INFLUX_URL;" ;;
      *'"error"'*)             _fail="$_fail $_area: influx refused: $(printf '%s' "$_body" | cut -c1-120);" ;;
      *'"series"'*'"values"'*) _ok=$((_ok+1)) ;;
      *)                       _fail="$_fail $_area: no hm_liveness row within $LIVENESS_WINDOW;" ;;
    esac
  done
  unset _iu _ip
  [ "$_n" -gt 0 ] || { echo "0 rooms with a dedicated sensor — nothing inspected"; return 1; }
  if [ -n "$_fail" ]; then echo "$_ok/$_n rooms have a fresh hm_liveness row;$_fail"; return 1; fi
  echo "$_ok/$_n rooms with a dedicated sensor have a gd_data.hm_liveness row younger than $LIVENESS_WINDOW"
}
H07_DESC="engine liveness: gd_data.hm_liveness row per room (tag room=<area_id>) younger than $LIVENESS_WINDOW, under the engine's own credential"
if [ "$TRV_COUNT" -eq 0 ]; then
  skip_test "HEAT-07" "$H07_DESC" "no TRV paired"
elif [ "$ROOMS_WITH_SENSOR" -eq 0 ]; then
  skip_test "HEAT-07" "$H07_DESC" "no room entity with a dedicated room sensor (temperature_source: valve everywhere)"
elif [ -z "$ENGINE" ]; then
  skip_test "HEAT-07" "$H07_DESC" "decision engine not installed — HEAT-07 needs $ENGINE_SLUG >= 2.0.0"
elif [ -z "$(ctr_of ga_influxdbv1)" ]; then
  skip_test "HEAT-07" "$H07_DESC" "ga_influxdbv1 container absent — nothing to query (addons_running ADR-03 covers it)"
elif ! command -v curl >/dev/null 2>&1; then
  skip_test "HEAT-07" "$H07_DESC" "no credential path for local InfluxDB from the host (curl absent)"
elif ! influx_cred; then
  skip_test "HEAT-07" "$H07_DESC" "no credential path for local InfluxDB from the host ($ENGINE_SLUG options.json without INFLUXDB_USERNAME/INFLUXDB_PASSWORD)"
else
  run_test_show "HEAT-07" "$H07_DESC" 'heat07'
fi

# =========================================================================
# HEAT-08 — one long-lived MQTT client
# =========================================================================
# The engine holds exactly ONE MQTT client (id ga_hmvapp_decisions) and
# reconnects only when the broker restarts. Mosquitto logs every connect as
# "New client connected from <ip>:<port> as <clientid> (...)". Two counts over
# the last 10 minutes, each allowed <= 10:
#   * connects whose client id starts with ga_hmvapp — the contract's own id;
#   * connects from the engine container's address — because hmvapp 1.7.1
#     opened a fresh client for EVERY read and write (several per valve per
#     3-second cycle, K31 rc22, 2026-09-03) under paho's random ids, which the
#     prefix alone would never see. The address is read from docker inspect
#     and used only as a grep key; the message carries counts, never the address.
# The total connect count is reported for coverage (rule 9).
heat08() {
  _mq=$(ctr_of ga_mosquitto)
  _log=$(docker logs --since "$SET_WINDOW" "$_mq" 2>&1 | grep "New client connected")
  _total=$(printf '%s\n' "$_log" | grep -c "New client connected")
  _byid=$(printf '%s\n' "$_log" | sed -n 's/.*New client connected from [^ ]* as \([^ ]*\).*/\1/p' | grep -c "^$ENGINE_CLIENT_PREFIX")
  _eip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$ENGINE" 2>/dev/null | head -1)
  _byip="n/a"
  [ -n "$_eip" ] && _byip=$(printf '%s\n' "$_log" | grep -c "connected from $_eip:")
  echo "last $SET_WINDOW: $_total client connects total, $_byid with client id ${ENGINE_CLIENT_PREFIX}*, $_byip from the engine's address (max $MQTT_CONNECT_MAX each)"
  [ "$_byid" -le "$MQTT_CONNECT_MAX" ] || return 1
  [ "$_byip" = "n/a" ] || [ "$_byip" -le "$MQTT_CONNECT_MAX" ]
}
H08_DESC="one long-lived MQTT client: <= $MQTT_CONNECT_MAX connects as ${ENGINE_CLIENT_PREFIX}* (and from the engine's address) in the mosquitto log, $SET_WINDOW"
if [ -z "$(ctr_of ga_mosquitto)" ]; then
  skip_test "HEAT-08" "$H08_DESC" "ga_mosquitto container absent — no broker log to inspect"
elif [ -z "$ENGINE" ]; then
  skip_test "HEAT-08" "$H08_DESC" "decision engine not installed — HEAT-08 needs $ENGINE_SLUG >= 2.0.0"
else
  run_test_show "HEAT-08" "$H08_DESC" 'heat08'
fi

rm -f "$STATES" "$SET_COUNTS"
suite_end
