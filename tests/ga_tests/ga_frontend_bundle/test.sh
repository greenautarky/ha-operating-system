#!/bin/sh
# ga_frontend_bundle verification — runs ON the device.
#
# The de-HACS Lovelace card bundle: a STATELESS custom_component (no config_flow,
# no Store) that serves the vendored card .js files as a static dir and injects
# each as a frontend JS module (add_extra_js_url) so the custom:* elements
# resolve on every dashboard. ga_manager's converge places it into
# /config/custom_components and activates it via the configuration.yaml
# enable-list (`ga_frontend_bundle:`). Source repo: greenautarky/ga-frontend-bundle.
#
# Runtime registration is proven WITHOUT an auth token: registered static paths
# and frontend extra-module <script> tags are both served unauthenticated.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Frontend bundle (ga_frontend_bundle)"

HA="http://localhost:8123"
COMP="/mnt/data/supervisor/homeassistant/custom_components/ga_frontend_bundle"
CARDS="$COMP/community/cards.json"
CFG="/mnt/data/supervisor/homeassistant/configuration.yaml"
STATIC="/ga_frontend_bundle_static"

# Card list + count from the on-device cards.json (empty/0 if absent).
ROWS=$(jq -r '.cards[] | .id + "/" + .file' "$CARDS" 2>/dev/null)
NCARDS=$(jq '.cards | length' "$CARDS" 2>/dev/null)
[ -z "$NCARDS" ] && NCARDS=0
FIRST=$(echo "$ROWS" | head -1)

_all_cards_on_disk() {
  [ -n "$ROWS" ] || return 1
  for r in $ROWS; do [ -f "$COMP/community/$r" ] || return 1; done
  return 0
}

_all_cards_serve() {
  [ -n "$ROWS" ] || return 1
  for r in $ROWS; do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "$HA$STATIC/$r")" = "200" ] || return 1
  done
  return 0
}

# add_extra_js_url injects <script type="module" src="/ga_frontend_bundle_static/...">
# into the served index HTML; the unique count must equal the vendored card count.
_all_modules_injected() {
  [ "$NCARDS" -ge 1 ] || return 1
  got=$(curl -sL --connect-timeout 5 "$HA/" | grep -oE "$STATIC/[^\"']+" | sort -u | wc -l)
  [ "$got" -eq "$NCARDS" ]
}

_no_setup_failure() {
  ! ha core logs --no-progress 2>/dev/null \
    | grep -iE "setup failed for ga_frontend_bundle|error during setup of (component )?ga_frontend_bundle"
}

# --- Placement (converge) ---
run_test "FB-01" "ga_frontend_bundle custom_component placed in /config" \
  "[ -f '$COMP/manifest.json' ]"

run_test "FB-02" "manifest declares domain ga_frontend_bundle" \
  "jq -e '.domain == \"ga_frontend_bundle\"' '$COMP/manifest.json' >/dev/null 2>&1"

run_test "FB-03" "stateless integration (manifest has no config_flow)" \
  "! jq -e '.config_flow == true' '$COMP/manifest.json' >/dev/null 2>&1"

# --- Vendored cards present ---
run_test "FB-04" "cards.json present and lists >=1 card" \
  "[ '$NCARDS' -ge 1 ]"

run_test "FB-05" "every card in cards.json is on disk" "_all_cards_on_disk"

# --- Activation (enable-list) ---
# converge activates integrations via ga_packages/ga_integrations.yaml (pulled in
# by `packages: !include_dir_named ga_packages`), not in configuration.yaml itself.
run_test "FB-06" "ga_frontend_bundle: enable-list entry present (configuration.yaml or ga_packages/)" \
  "cat '$CFG' \"$(dirname "$CFG")\"/ga_packages/*.yaml 2>/dev/null | grep -qE '^ga_frontend_bundle:'"

# --- Runtime: integration loaded + static path registered (no auth needed) ---
run_test "FB-07" "integration loaded — static path serves a card 200 ($FIRST)" \
  "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 '$HA$STATIC/$FIRST')\" = \"200\" ]"

run_test "FB-08" "all $NCARDS cards serve via $STATIC (HTTP 200)" "_all_cards_serve"

# --- Runtime: cards actually wired into the frontend ---
# add_extra_js_url only injects script tags into the AUTHENTICATED dashboard
# HTML — not into HA's stock onboarding page nor the /auth/authorize page.
# So the index-grep below is only meaningful once HA's own onboarding flow
# has completed (= all four standard steps user/core_config/analytics/integration
# marked done). Until then, FB-09 would fail not because of an integration
# bug but because the page served at `/` has no extra_module_url slot at all.
# Confirmed BOSv1.2.0 build #10 bench, 2026-06-02.
_ha_stock_onboarded() {
  local body
  body=$(curl -sL --connect-timeout 5 "$HA/api/onboarding" 2>/dev/null) || return 1
  [ -z "$body" ] && return 1
  # 4 steps required; jq returns true only when every .done is true.
  echo "$body" | jq -e 'length==4 and all(.[]; .done==true)' >/dev/null 2>&1
}
if _ha_stock_onboarded; then
  run_test "FB-09" "all $NCARDS card modules injected into frontend index (add_extra_js_url)" \
    "_all_modules_injected"
else
  skip_test "FB-09" "HA stock onboarding not complete (extra_module_url tags only land on the authenticated dashboard)"
fi

# --- Health (informational) ---
warn_test "FB-10" "no setup failure for ga_frontend_bundle in Core log" "_no_setup_failure"

suite_end
