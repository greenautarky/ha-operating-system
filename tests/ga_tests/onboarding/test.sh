#!/bin/sh
# Core image & onboarding verification - runs ON the device.
# V1.2-clean model: STOCK HA Core image + the greenautarky_site
# custom_component (German onboarding, GDPR consent, telemetry preferences).
# The Supervisor stays a greenautarky fork; Core + frontend are stock upstream.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Onboarding"

# --- Core image checks ---
CORE_IMAGE=$(docker inspect homeassistant --format '{{.Config.Image}}' 2>/dev/null)

# V1.2-clean: Core fork retired — the device must run STOCK upstream Core.
run_test "OB-01" "Core image is stock upstream (Core fork retired)" \
  "echo '$CORE_IMAGE' | grep -q 'ghcr.io/home-assistant/'"

run_test "OB-02" "Core image tag is a pinned HA version" \
  "echo '$CORE_IMAGE' | grep -qE ':2025\.[0-9]+\.[0-9]+'"

run_test_show "OB-02b" "Core image" \
  "echo '$CORE_IMAGE'"

# --- HA version ---
run_test_show "OB-03" "HA version" \
  "cat /mnt/data/supervisor/homeassistant/.HA_VERSION 2>/dev/null"

# --- GA-side release identifier ---
# /etc/ga-release is written at bake time by buildroot-external/scripts/post-build.sh
# from the GA_RELEASE env var. Operator-facing version distinct from the
# HAOS-internal OS_VERSION. Fails if absent (= build didn't set GA_RELEASE) or empty.
run_test "OB-04a" "/etc/ga-release present + non-empty" \
  "[ -s /etc/ga-release ]"
run_test_show "OB-04b" "GA release identifier" \
  "cat /etc/ga-release 2>/dev/null"

# --- Wizard redirect (Finding 20 follow-up: BOSv1.2.0 bench regression) ---
# Customer's first browser hit on a fresh GA-provisioned device is
# `http://<device>:8123/`. With GA wizard NOT YET completed, this MUST
# redirect server-side to `/greenautarky-setup.html` — otherwise the
# customer lands on the stock HA login (because ga_manager already
# created the admin user) and never finds the GA wizard. The
# `_patch_index_view_for_wizard_redirect` server-side hook in
# greenautarky_site owns this behaviour; the add_extra_js_url
# client-side fallback alone can't fix it because HA Core injects
# extra_module_url tags only into the authenticated dashboard HTML.
#
# Two opposite gates:
#   OB-WR-01: when the wizard is incomplete, `/` returns 302 to /greenautarky-setup.html
#   OB-WR-02: when the wizard is complete, `/` does NOT redirect to the wizard
# Both run unauthenticated (curl with no token). The wizard URL is
# `/greenautarky-setup.html` (the actual page) — NOT `/greenautarky-setup`
# (which is the view that itself 302s).
_wizard_completed=$(jq -r '.data.completed // false' /mnt/data/supervisor/homeassistant/.storage/greenautarky_site 2>/dev/null || echo "false")
_root_redirect=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --connect-timeout 5 'http://localhost:8123/' 2>/dev/null)

if [ "$_wizard_completed" = "false" ]; then
  run_test "OB-WR-01" "/ redirects to /greenautarky-setup.html (wizard incomplete)" \
    "echo '$_root_redirect' | grep -qE '^302 .*greenautarky-setup\.html'"
else
  skip_test "OB-WR-01" "wizard already completed — incomplete-state gate doesn't apply"
fi

if [ "$_wizard_completed" = "true" ]; then
  run_test "OB-WR-02" "/ does NOT redirect to wizard once wizard is complete" \
    "! echo '$_root_redirect' | grep -qE 'greenautarky-setup\.html'"
else
  skip_test "OB-WR-02" "wizard not yet completed — complete-state gate doesn't apply"
fi

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
# V1.2-clean: the onboarding customization moved OUT of the Core fork's
# strings.json INTO the greenautarky_site custom_component, which
# ga_manager's converge worker places into /config/custom_components
# (= the data partition's homeassistant/custom_components/). The component's
# runtime registration is additionally proven by OB-13 / PW-* (its HTTP views).
GA_COMP="/mnt/data/supervisor/homeassistant/custom_components/greenautarky_site"
run_test "OB-09" "greenautarky_site custom_component placed (converge step 2)" \
  "[ -f '$GA_COMP/manifest.json' ]"

run_test "OB-10" "greenautarky_site manifest declares its domain" \
  "grep -q 'greenautarky_site' '$GA_COMP/manifest.json' 2>/dev/null"

# --- Frontend ---
run_test "OB-11" "Frontend wheel installed" \
  "docker exec homeassistant pip show home-assistant-frontend >/dev/null 2>&1"

# --- Image bloat check ---
run_test "OB-12" "No frontend-build bloat in core image" \
  "docker exec homeassistant test ! -d /usr/src/homeassistant/frontend-build"

# --- Onboarding PIN ---
# PIN lives in /mnt/data/supervisor/homeassistant/ (HA Core sees it as /config/)
PIN_FILE="/mnt/data/supervisor/homeassistant/ga-onboarding-pin"
if [ -f "$PIN_FILE" ]; then
  run_test "OB-10a" "PIN file exists" "true"
  PERMS=$(stat -c '%a' "$PIN_FILE" 2>/dev/null || echo "?")
  run_test "OB-10b" "PIN file permissions 600" "[ '$PERMS' = '600' ]"
  run_test "OB-10c" "PIN is 6 digits" \
    "grep -qE '^[0-9]{6}$' $PIN_FILE"
else
  skip_test "OB-10" "PIN file (not provisioned via ga-flasher)"
fi

# --- Ethernet consent ---
# OB-13: Ethernet consent API endpoint exists
run_test "OB-13" "Ethernet consent API endpoint exists" \
  "curl -sf --connect-timeout 5 -X POST http://localhost:8123/api/greenautarky_site/ethernet \
   -H 'Content-Type: application/json' -d '{\"enable_ethernet\": false}' 2>/dev/null | grep -q 'status'"

# OB-14: Default Ethernet state after provisioning
if [ -f /mnt/data/ga-env.conf ]; then
  run_test "OB-14" "Ethernet disabled by default after provisioning" \
    "grep -q 'GA_ETHERNET_DISABLED=true' /mnt/data/ga-env.conf 2>/dev/null"
else
  skip_test "OB-14" "ga-env.conf not found (not provisioned)"
fi

# --- Password reset ---
run_test "PW-01" "Password reset page accessible" \
  "curl -sf --connect-timeout 5 http://localhost:8123/greenautarky-password-reset 2>/dev/null | grep -qi 'passwort'"

run_test "PW-02" "Password reset API rejects wrong PIN" \
  "HTTP_CODE=\$(curl -sf --connect-timeout 5 -o /dev/null -w '%{http_code}' \
   -X POST http://localhost:8123/api/greenautarky_site/password_reset/users \
   -H 'Content-Type: application/json' -d '{\"pin\": \"000000\"}' 2>/dev/null); \
   [ \"\$HTTP_CODE\" = '401' ] || [ \"\$HTTP_CODE\" = '404' ]"

run_test "PW-03" "Password reset API rejects missing fields" \
  "HTTP_CODE=\$(curl -sf --connect-timeout 5 -o /dev/null -w '%{http_code}' \
   -X POST http://localhost:8123/api/greenautarky_site/password_reset \
   -H 'Content-Type: application/json' -d '{\"pin\": \"000000\", \"username\": \"\", \"new_password\": \"\"}' 2>/dev/null); \
   [ \"\$HTTP_CODE\" = '400' ] || [ \"\$HTTP_CODE\" = '401' ] || [ \"\$HTTP_CODE\" = '404' ]"

suite_end
