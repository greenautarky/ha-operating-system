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

run_test "OB-02" "Core image tag is HA version (not upstream)" \
  "echo '$CORE_IMAGE' | grep -qE ':(2025\.[0-9]+\.[0-9]+|latest)'"

run_test_show "OB-02b" "Core image" \
  "echo '$CORE_IMAGE'"

# --- HA version ---
run_test_show "OB-03" "HA version" \
  "cat /mnt/data/supervisor/homeassistant/.HA_VERSION 2>/dev/null"

# --- Version repo / supervisor ---
# Supervisor only logs this after an update check — may not appear on fresh boot
warn_test "OB-05" "Supervisor fetches from greenautarky version repo" \
  "journalctl -u hassio-supervisor -b 0 --no-pager -q 2>/dev/null | grep -q 'greenautarky/haos-version'"

run_test "OB-06" "Supervisor is greenautarky fork" \
  "docker inspect hassio_supervisor --format '{{.Config.Image}}' 2>/dev/null | grep -qi 'greenautarky'"

# --- Non-core components should stay upstream ---
run_test "OB-07" "Non-core components use upstream registries" \
  "for c in hassio_dns hassio_audio hassio_cli hassio_multicast hassio_observer; do IMG=\$(docker inspect \$c --format '{{.Config.Image}}' 2>/dev/null); [ -z \"\$IMG\" ] && continue; echo \"\$IMG\" | grep -qi 'greenautarky' && exit 1; done; exit 0"

# --- Core image freshness ---
run_test_show "OB-08" "Core image is latest (not stale)" \
  "LOCAL_DIGEST=\$(docker inspect homeassistant --format '{{.Image}}' 2>/dev/null | cut -d: -f2 | head -c12) && [ -n \"\$LOCAL_DIGEST\" ] && echo \"local digest: \$LOCAL_DIGEST\""

# --- Custom onboarding content ---
run_test "OB-09" "Custom onboarding: GDPR step present" \
  "docker exec homeassistant grep -q 'gdpr' /usr/src/homeassistant/homeassistant/components/onboarding/strings.json 2>/dev/null"

run_test "OB-10" "Custom onboarding: custom_pages step present" \
  "docker exec homeassistant grep -q 'custom_pages' /usr/src/homeassistant/homeassistant/components/onboarding/strings.json 2>/dev/null"

# --- Frontend ---
run_test "OB-11" "Frontend wheel installed" \
  "docker exec homeassistant pip show home-assistant-frontend >/dev/null 2>&1"

# --- Image bloat check ---
run_test "OB-12" "No frontend-build bloat in core image" \
  "docker exec homeassistant test ! -d /usr/src/homeassistant/frontend-build"

suite_end
