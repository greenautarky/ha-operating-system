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

# --- coverage --------------------------------------------------------------
# A loop over zero components is a broken generator, not a clean device.
run_test "FEAT-98" "coverage: four components were checked, not zero" \
  '[ "$(ls '"$VENDORED"' 2>/dev/null | grep -c -E "^(ga_heating|greenautarky_site|greenautarky_telemetry|ga_frontend_bundle)$")" -eq 4 ]'

suite_end
