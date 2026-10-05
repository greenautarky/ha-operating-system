#!/bin/sh
# HA Core -> device-local InfluxDB: does Core actually WRITE into ga_homeassistant_db?
#
# BOSv1.4.0-rc2: nothing configured Home Assistant Core's InfluxDB integration,
# so Core wrote nothing into ga_homeassistant_db — the database ga_hmvapp_addon
# and ga_default_addon read room temperatures from (measurement "°C"). The fix
# is ga_manager's `ha_influxdb` reconciler (0.221.0): on Core 2026.8 the
# integration is a CONFIG ENTRY (YAML connection keys are imported once and
# then ignored), created through Core's own config flow.
#
#   HAIX-01  Core holds ONE influxdb config entry for ga_homeassistant_db as
#            ga_ha_influx_user (read from Core's own .storage, host side).
#   HAIX-02  the OUTCOME: Core's newest "°C" point in ga_homeassistant_db is no
#            more than 15 min behind Core's newest °C state update. Core writes
#            on a state CHANGE, so the reference is Core's own state machine,
#            not the wall clock: a flat whose temperatures did not change is not
#            stale. No point at all while Core has °C entities is the rc2 shape.
#            Queried as Core's own entry credential, read from .storage into
#            shell variables and handed to curl via --data-urlencode — never
#            echoed; every message is built from the response.
#
# Run AFTER converge. HAIX-02 waits (bounded, GA_HAIX_WAIT_S, default 900 s)
# for a point to appear — a freshly created entry writes on the next change —
# and on timeout asserts anyway, so "never wrote" fails loudly.
#
# Host tools: docker, jq (BR2_PACKAGE_JQ=y, built WITHOUT oniguruma: no
# test()/match(); startswith/contains/fromdateiso8601 only), curl, date +%s.
#
# Fixture run (no device): selftest.sh drives THIS script over fixtures/ with a
# docker/curl shim; overrides GA_HAIX_HA_DIR, GA_HAIX_TMP, GA_HAIX_WAIT_S.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
set -u

suite_start "HA Core InfluxDB integration (Core writes into ga_homeassistant_db)"

HA_DIR="${GA_HAIX_HA_DIR:-/mnt/data/supervisor/homeassistant}"
ENTRIES="$HA_DIR/.storage/core.config_entries"
TMP_DIR="${GA_HAIX_TMP:-/tmp}"
STATES="$TMP_DIR/ga-haix-celsius.json"
WAIT_S="${GA_HAIX_WAIT_S:-900}"
INFLUX_URL="http://127.0.0.1:8086"     # ga_influxdbv1 maps 8086/tcp onto the host
DB="ga_homeassistant_db"
USER_WANT="ga_ha_influx_user"
LAG_MAX_S=900

ctr_of() { docker ps --format '{{.Names}}' 2>/dev/null | grep -E "^addon_.*_$1\$" | head -1; }

# --- HAIX-01: the entry ------------------------------------------------------
entry_line() {
  jq -r '[.data.entries[]? | select(.domain == "influxdb")]
         | "\(length) \(.[0].data.database // "-") \(.[0].data.username // "-") \(.[0].data.api_version // "1")"' \
     "$ENTRIES" 2>/dev/null
}
haix01() {
  [ -s "$ENTRIES" ] || { echo "$ENTRIES missing or empty"; return 1; }
  set -- $(entry_line)
  [ "${1:-0}" -ge 1 ] || { echo "no influxdb config entry in Core — Core writes nothing into $DB (the rc2 shape)"; return 1; }
  [ "$1" -eq 1 ] || { echo "$1 influxdb entries (single_config_entry integration)"; return 1; }
  [ "$4" = "1" ] || { echo "entry is InfluxDB API v$4, not the device-local 1.x"; return 1; }
  [ "$2" = "$DB" ] || { echo "entry writes into '$2', not $DB"; return 1; }
  [ "$3" = "$USER_WANT" ] || { echo "entry authenticates as '$3', not $USER_WANT"; return 1; }
  echo "one influxdb entry -> $DB as $USER_WANT"
}
run_test_show "HAIX-01" "Core has one InfluxDB config entry -> $DB as $USER_WANT" 'haix01'

# --- Core's °C entities, through ga_manager (it holds the SUPERVISOR_TOKEN) ---
: > "$STATES"
GM="$(ctr_of ga_manager)"
if [ -n "$GM" ]; then
  docker exec "$GM" sh -c \
    'curl -fsS -m 20 -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/api/states' 2>/dev/null \
    | jq -c '[ .[] | select((.attributes.unit_of_measurement // "") == "°C")
                   | select(.state != "unknown" and .state != "unavailable" and .state != "")
                   | {entity_id, last_updated} ]' > "$STATES" 2>/dev/null \
    || : > "$STATES"
fi
CELSIUS=$(jq 'length' "$STATES" 2>/dev/null || echo 0)
# HA writes "2026-10-05T11:56:00.123456+00:00"; jq's fromdateiso8601 wants
# "…Z" without fractions. last_updated is always UTC.
CORE_NEWEST=$(jq -r 'map(.last_updated[0:19] + "Z" | fromdateiso8601) | max // empty' "$STATES" 2>/dev/null)

entry_cred() {
  _iu=$(jq -r '[.data.entries[]? | select(.domain == "influxdb")][0].data.username // empty' "$ENTRIES" 2>/dev/null)
  _ip=$(jq -r '[.data.entries[]? | select(.domain == "influxdb")][0].data.password // empty' "$ENTRIES" 2>/dev/null)
  [ -n "$_iu" ] && [ -n "$_ip" ]
}
newest_point() {
  entry_cred || return 1
  _body=$(curl -s -m 15 -G "$INFLUX_URL/query" \
            --data-urlencode "u=$_iu" --data-urlencode "p=$_ip" \
            --data-urlencode "db=$DB" --data-urlencode "epoch=s" \
            --data-urlencode 'q=SELECT * FROM "°C" ORDER BY time DESC LIMIT 1' 2>/dev/null)
  unset _iu _ip
  printf '%s' "$_body" | jq -r '.results[0].series[0].values[0][0] // empty' 2>/dev/null
}
haix02() {
  [ -n "$CORE_NEWEST" ] || { echo "Core's newest °C update unreadable"; return 1; }
  entry_cred || { echo "Core has no InfluxDB entry — it cannot have written (the rc2 shape)"; return 1; }
  unset _iu _ip
  _pt=$(newest_point)
  case "$_pt" in
    ''|*[!0-9]*) echo "no \"°C\" point in $DB although Core has $CELSIUS °C entities — Core is not writing"; return 1 ;;
  esac
  _lag=$(( CORE_NEWEST - _pt ))
  [ "$_lag" -lt 0 ] && _lag=0
  if [ "$_lag" -gt "$LAG_MAX_S" ]; then
    echo "newest \"°C\" point is $((_lag / 60)) min behind Core's newest °C update (max $((LAG_MAX_S / 60)))"
    return 1
  fi
  echo "newest \"°C\" point ${_lag}s behind Core's newest °C update ($CELSIUS °C entities)"
}
H02_DESC="Core writes: newest $DB.\"°C\" point <= $((LAG_MAX_S / 60)) min behind Core's newest °C state update"
if [ -z "$GM" ]; then
  run_test_show "HAIX-02" "$H02_DESC" 'echo "ga_manager container not running — Core states unreadable"; false'
elif [ "${CELSIUS:-0}" -eq 0 ]; then
  skip_test "HAIX-02" "$H02_DESC" "no °C entity in Core — nothing for Core to write"
elif [ -z "$(ctr_of ga_influxdbv1)" ]; then
  skip_test "HAIX-02" "$H02_DESC" "ga_influxdbv1 container absent (addons_running covers it)"
elif ! command -v curl >/dev/null 2>&1; then
  skip_test "HAIX-02" "$H02_DESC" "curl absent on the host"
else
  run_test_ready "HAIX-02" "$H02_DESC" 'haix02' "$WAIT_S" 'haix02'
fi

suite_end
