#!/bin/sh
# device_features — the FEATURE surface, on the device that ships it.
#
# The other two suites answer different questions. os_integrity asks "is the
# flashed artefact what master declared"; addons_running asks "is every add-on
# up and answering". Neither notices a feature that was built, pinned, baked,
# and then does nothing — which is the failure this project keeps paying for:
# a component placed but never loaded, a metric written where nothing collects
# it, a security fix published and pinned by nobody.
#
# Every assertion here was MEASURED on K31 with BOSv1.3.0-rc7 on 2026-08-24
# before it was written down. Nothing here is aspirational.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Device Features (built, shipped, and actually doing something)"

SHARE=/mnt/data/supervisor/share
HACONF=/mnt/data/supervisor/homeassistant
VENDORED=/usr/share/ga/custom_components
DROP="$SHARE/telegraf"

# --- the /share bridge -----------------------------------------------------
# A live credential on the add-on<->host bridge, readable by every `share:rw`
# add-on. The fix shipped in ga_influxdbv1 0.0.7 on 2026-08-21 and reached no
# device until it was pinned: the same file was still 644 on this device an
# hour before this suite was written. Mode, not existence, is the assertion.
run_test_show "FEAT-01" "influx /share secret is 0600, not world-readable" \
  '[ ! -e '"$SHARE"'/influxdb_password.yaml ] || [ "$(stat -c %a '"$SHARE"'/influxdb_password.yaml)" = "600" ]'

# --- host firewall ---------------------------------------------------------
# Current HA Core serves its UI on :80. Without this the allowlist blackholes
# it on eth0/wlan0 while the mesh still works — an on-site-only breakage, i.e.
# invisible to every remote check we have.
run_test_show "FEAT-02" "firewall admits :80 AND :8123 on the LAN interfaces" \
  'nft list table inet ga_firewall 2>/dev/null | grep -qE "iifname \{ \"eth0\", \"wlan0\" \} tcp dport \{[^}]*\<80\>[^}]*\<8123\>[^}]*\}"'

# The comma in CONTAINER_ALLOW_TCP is load-bearing: a space produces a set nft
# rejects, and ga-firewall-gate DELETES the table on a failed load — so the
# device would ship UNFILTERED. Assert the table exists at all, because that is
# what "the load succeeded" looks like from here.
run_test "FEAT-03" "firewall table is loaded (a rejected set would have deleted it)" \
  'nft list tables 2>/dev/null | grep -q "inet ga_firewall"'

# --- vendored components: staged, placed, and LOADED -----------------------
# Three distinct states, and the gap between the second and third is where a
# component silently does nothing. `async_load_platform` not reaching a platform
# has cost this project a day before.
for _c in ga_heating greenautarky_site greenautarky_telemetry ga_frontend_bundle; do
  run_test "FEAT-04/$_c" "component staged in the read-only image" \
    "[ -d '$VENDORED/$_c' ]"
done
for _c in ga_heating greenautarky_site greenautarky_telemetry ga_frontend_bundle; do
  run_test "FEAT-05/$_c" "component placed into HA Core's config" \
    "[ -f '$HACONF/custom_components/$_c/manifest.json' ]"
done
# Placed is not loaded. HA's loader emits a line per custom integration it
# actually loads; absence of that line is the whole point of this check.
for _c in ga_heating greenautarky_site greenautarky_telemetry ga_frontend_bundle; do
  run_test "FEAT-06/$_c" "HA Core LOADED the component (loader saw it)" \
    "docker logs homeassistant 2>&1 | grep -q 'custom integration $_c'"
done

# --- the feature actually produces something -------------------------------
# ga-heating 0.2.0 registers a health entity so the heating plane is observable
# from off the device. If the integration loads but registers nothing, the
# checks above stay green and the feature is still inert.
run_test_show "FEAT-07" "ga_heating registered its health entity" \
  'grep -q "sensor.ga_heating_health" '"$HACONF"'/.storage/core.entity_registry'

# --- the room-thermostat plane (ga-heating 0.2.0) --------------------------
# The INVARIANT, not this device's furniture: every area that owns a radiator
# must own a ga_heating room thermostat. That holds on a device with three rooms
# and on one with none — where it degenerates to "0 == 0", which is why FEAT-15
# says out loud when there is nothing to prove.
#
# Measured on K31 2026-08-24 after the K0 valves were migrated onto it: three
# areas with radiators, three thermostats, each assigned to its own area.
_REG="$HACONF/.storage/core.entity_registry"

# ⚠️ .storage is written LAZILY. Reading it seconds after a Core restart shows a
# registry that has not been flushed yet — that cost a wrong conclusion on the
# day this was written ("the thermostats do not exist"; they did). This suite
# runs long after startup, but if it ever moves earlier, wait for the flush
# rather than trusting an empty answer.
_areas_with_radiator() {
  # A radiator is a z2m climate entity; its area comes from its DEVICE.
  sed -n 's/.*"area_id": *"\([a-z_0-9]*\)".*/\1/p' "$HACONF/.storage/core.device_registry" 2>/dev/null | sort -u
}
_ga_thermostats() {
  grep -o '"unique_id":"ga_heating_[a-z_0-9]*"' "$_REG" 2>/dev/null \
    | sed 's/.*ga_heating_//; s/"//' | grep -v '^health$' | sort -u
}

run_test_show "FEAT-12" "ga_heating registered a room thermostat per area with a radiator" \
  '[ "$(grep -c "\"unique_id\":\"ga_heating_" '"$_REG"' 2>/dev/null)" -ge 2 ]'

# Registering is not enough: a thermostat in no room controls nothing a resident
# can find. The component assigns its own area after registration, so this is a
# separate step that can separately fail.
run_test_show "FEAT-13" "every room thermostat is assigned to an area" \
  '! grep -o "\"unique_id\":\"ga_heating_[a-z_0-9]*\"[^}]*" '"$_REG"' 2>/dev/null | grep -v ga_heating_health | grep -q "\"area_id\":null"'

# The 0.2.0 promise: a room that cannot be measured SAYS so. Silence here is the
# failure mode this replaced — a room heated off its own valve's sensor while
# everything looked healthy.
run_test_show "FEAT-14" "a room lacking its own thermometer is REPORTED, not silently degraded" \
  'docker logs homeassistant 2>&1 | grep -q "no temperature sensor of its own" || ! docker logs homeassistant 2>&1 | grep -q "custom_components.ga_heating.climate"'

# Coverage, and honest about it: with no radiators paired there is nothing to
# assert, and this says so instead of passing quietly.
run_test_show "FEAT-15" "coverage: radiators are actually paired (else FEAT-12..14 prove nothing)" \
  '[ "$(grep -c "\"platform\":\"mqtt\"[^}]*climate\." '"$_REG"' 2>/dev/null)" -gt 0 ] || [ "$(grep -o "climate\.0x[0-9a-f]*" '"$_REG"' 2>/dev/null | sort -u | wc -l)" -gt 0 ]'

# --- the metric bridge -----------------------------------------------------
# Telegraf must read the drop DIRECTORY. Hardcoding one filename meant the
# second writer was collected by nothing, and a metric that never arrives looks
# exactly like a healthy fleet.
run_test_show "FEAT-08" "telegraf collects the drop DIRECTORY, not one filename" \
  'grep -E "^[[:space:]]*files[[:space:]]*=" /etc/telegraf/telegraf.conf 2>/dev/null | grep -q "telegraf/\*\.influx"'

# And that this is not theoretical: more than one writer is actually dropping
# files. With a single writer the glob and a hardcoded name behave identically,
# so this is what makes FEAT-08 mean anything.
run_test_show "FEAT-09" "more than one writer drops into the directory" \
  '[ "$(ls '"$DROP"'/*.influx 2>/dev/null | wc -l)" -ge 2 ]'

# Telemetry is consent-gated. Asserting the CONDITION rather than the state:
# telegraf being inactive on a device without consent is correct, and a suite
# that demanded "active" would push people to defeat the gate.
run_test "FEAT-10" "telegraf is gated on an explicit metrics consent marker" \
  'systemctl cat telegraf 2>/dev/null | grep -q "ConditionPathExists=/mnt/data/.ga-consent-metrics"'

# --- credentials out of the image ------------------------------------------
# ga_default_addon 1.4.0 stopped baking cloud database credentials into the
# image. Assert on the SHAPE (no password-bearing key), never on a value.
run_test_show "FEAT-11" "ga_default_addon carries no cloud DB password in its options" \
  '! grep -qiE "\"(DB_PASSWORD|POSTGRES_PASSWORD|CLOUD_DB_PASSWORD)\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" /mnt/data/supervisor/addons/data/*_ga_default_addon/options.json 2>/dev/null'

# --- Home Assistant's OWN onboarding (ga_manager 0.130.0, #215) ------------
# Provisioning owns this, not the resident. Core's onboarding has four steps and
# only the first one is unauthenticated; the call that completes it returns the
# token every later step needs. Before 0.130.0 that token was discarded, so
# core_config was posted empty and analytics + integration were never posted at
# all — and because an HTTP 401 raises nothing inside a try/except, the failure
# left no log line whatsoever. What a resident saw was Home Assistant asking for
# a location the device already had.
#
# Asserted against CORE'S OWN store rather than converge's job output: a job that
# reports success is not evidence that Core agrees. An ABSENT store is a skip and
# never a pass — Core may simply not have started yet.
_ONB="$HACONF/.storage/onboarding"
run_test_show "FEAT-16" "HA Core's own onboarding was finished by provisioning" \
  '[ -f '"$_ONB"' ] && for s in user core_config analytics integration; do
     grep -q "\"$s\"" '"$_ONB"' || { echo "missing step: $s"; exit 1; }
   done'

# The step above can be "done" while carrying nothing. This is the half a
# resident actually meets: core_config must hold the location converge seeded,
# because a device that onboarded with 0/0 asks for a location on first login —
# which is exactly the symptom that led to #215.
run_test_show "FEAT-17" "core_config carries a seeded location, so nobody is asked for one" \
  '_lat=$(sed -n "s/.*\"latitude\": *\([-0-9.]*\).*/\1/p" '"$HACONF"'/.storage/core.config 2>/dev/null | head -1);
   _lon=$(sed -n "s/.*\"longitude\": *\([-0-9.]*\).*/\1/p" '"$HACONF"'/.storage/core.config 2>/dev/null | head -1);
   [ -n "$_lat" ] && [ -n "$_lon" ] && [ "$_lat" != "0" ] && [ "$_lat" != "0.0" ] && [ "$_lon" != "0" ] && [ "$_lon" != "0.0" ]'

# --- coverage --------------------------------------------------------------
# A loop over zero components is a broken generator, not a clean device.
run_test "FEAT-98" "coverage: four components were checked, not zero" \
  '[ "$(ls '"$VENDORED"' 2>/dev/null | grep -c -E "^(ga_heating|greenautarky_site|greenautarky_telemetry|ga_frontend_bundle)$")" -eq 4 ]'

suite_end
