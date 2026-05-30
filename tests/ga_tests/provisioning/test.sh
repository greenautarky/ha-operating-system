#!/bin/sh
# Converge-provisioning verification - runs ON the device.
# Asserts the on-device EFFECTS of ga_manager's converge worker for the
# features moved out of ga-flasher-py (stages 64/65/69 + z2m channel 15) and
# the 0.24.0 provisioning self-check. This is an INDEPENDENT cross-check of
# converge step 8 / step 11 — it reads the real device state directly, so it
# does not rely on the self-check grading itself.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Provisioning"

HA_CFG="/mnt/data/supervisor/homeassistant"
Z2M_CFG="$HA_CFG/zigbee2mqtt/configuration.yaml"
ENTRIES="$HA_CFG/.storage/core.config_entries"

# --- converge completion (step 10) ---
# ga_manager (addon) writes /share/.ga_converged; the addon's /share is the
# host path /mnt/data/supervisor/share (NOT the host's own /share).
run_test "PROV-01" "converged marker present (/mnt/data/supervisor/share/.ga_converged)" \
  "[ -f /mnt/data/supervisor/share/.ga_converged ]"

# --- Zigbee2MQTT serial + channel (= flasher stage 64 / 0.23.2) ---
if [ -f "$Z2M_CFG" ]; then
  run_test "PROV-02" "z2m serial port = /dev/ttyS4 (stage 64)" \
    "grep -qE 'port:[[:space:]]*/dev/ttyS4' '$Z2M_CFG'"
  run_test "PROV-03" "z2m advanced.channel = 15 (0.23.2)" \
    "grep -qE '^[[:space:]]*channel:[[:space:]]*15[[:space:]]*\$' '$Z2M_CFG'"
else
  skip_test "PROV-02" "z2m configuration.yaml not found (zigbee not provisioned)"
  skip_test "PROV-03" "z2m configuration.yaml not found (zigbee not provisioned)"
fi

# --- HA-Core MQTT integration entry (= flasher stage 65) ---
run_test "PROV-04" "HA-Core MQTT config entry present (stage 65)" \
  "grep -qE '\"domain\":[[:space:]]*\"mqtt\"' '$ENTRIES' 2>/dev/null"

# --- load-bearing addon flags watchdog/auto_update (= flasher stage 69) ---
# Slugs are repo-prefixed (e.g. 99f1cad4_ga_mosquitto) — resolve by identity.
for ident in ga_mosquitto ga_zigbee2mqtt ga_ihosthardwarecontrol; do
  slug=$(ha addons --raw-json 2>/dev/null \
    | jq -r --arg s "$ident" '.data.addons[] | select(.slug==$s or (.slug|endswith("_"+$s))) | .slug' \
    | head -1)
  if [ -n "$slug" ]; then
    run_test "PROV-05-$ident" "$ident watchdog=true + auto_update=false (stage 69)" \
      "ha addons info '$slug' --raw-json 2>/dev/null | jq -e '.data.watchdog==true and .data.auto_update==false' >/dev/null"
  else
    skip_test "PROV-05-$ident" "$ident not installed (converge step 1 incomplete?)"
  fi
done

# --- provisioning self-check ran + PASSED (0.24.0, converge step 11) ---
GA_MGR=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i 'ga_manager' | head -1)
if [ -n "$GA_MGR" ]; then
  run_test "PROV-06" "converge self-check ran and PASSED (step 11)" \
    "docker logs '$GA_MGR' 2>&1 | grep -q 'self-check PASSED'"
else
  skip_test "PROV-06" "ga_manager container not found"
fi

suite_end
