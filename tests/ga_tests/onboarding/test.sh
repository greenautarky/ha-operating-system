#!/bin/sh
# Custom core image & onboarding verification - runs ON the device
# Verifies the device runs the greenautarky custom HA Core image
# (German onboarding, GDPR consent, telemetry preferences).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Onboarding"

# --- Core image checks ---
CORE_IMAGE=$(docker inspect homeassistant --format '{{.Config.Image}}' 2>/dev/null)

run_test "OB-01" "Core image is greenautarky (not upstream)" \
  "echo '$CORE_IMAGE' | grep -q 'greenautarky'"

run_test "OB-02" "Core image version is ga-tagged" \
  "echo '$CORE_IMAGE' | grep -q 'ga\.'"

run_test_show "OB-02b" "Core image" \
  "echo '$CORE_IMAGE'"

# --- HA version ---
run_test "OB-03" "HA version matches expected ga build" \
  "cat /mnt/data/supervisor/homeassistant/.HA_VERSION 2>/dev/null | grep -q 'ga\.'"

run_test_show "OB-03b" "HA version" \
  "cat /mnt/data/supervisor/homeassistant/.HA_VERSION 2>/dev/null"

# --- Version repo / supervisor ---
run_test "OB-05" "Supervisor fetches from greenautarky version repo" \
  "journalctl -u hassio-supervisor -b 0 --no-pager -q 2>/dev/null | grep -q 'greenautarky/haos-version'"

run_test "OB-06" "Supervisor is iHost fork" \
  "docker inspect hassio_supervisor --format '{{.Config.Image}}' 2>/dev/null | grep -qi 'ihost-open-source-project'"

# --- Non-core components should stay upstream ---
run_test "OB-07" "Non-core components use upstream registries" \
  "for c in hassio_dns hassio_audio hassio_cli hassio_multicast hassio_observer; do IMG=\$(docker inspect \$c --format '{{.Config.Image}}' 2>/dev/null); [ -z \"\$IMG\" ] && continue; echo \"\$IMG\" | grep -qi 'greenautarky' && exit 1; done"

suite_end
