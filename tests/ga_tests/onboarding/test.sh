#!/bin/sh
# Core image & onboarding verification - runs ON the device.
# Core is the GA armv7 build of upstream Core (unmodified source, built for
# armv7 because upstream stopped) + the greenautarky_site custom_component
# (German onboarding, GDPR consent, telemetry preferences).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Onboarding"

# --- Core image checks ---
CORE_IMAGE=$(docker inspect homeassistant --format '{{.Config.Image}}' 2>/dev/null)

# 2026-09-28: Core is the GA armv7 build — upstream stopped building armv7
# Core in late 2025, so the stock image is frozen at 2025.11.3.
run_test "OB-01" "Core image is the GA armv7 build" \
  "echo '$CORE_IMAGE' | grep -q '^ghcr.io/greenautarky/home-assistant-armv7:'"

# A floor, not a pin: any calver from 2026 on. The exact pin is OSI-04.
# An optional fourth component is the GA rebuild counter: 2026.8.2.1 is HA
# 2026.8.2, rebuilt with updated Python dependencies (version.yaml
# base_images.homeassistant_core). The three-part-only pattern called that pin
# "not pinned" on the first rc that carried it, while OSI-04 passed on the same
# tag — two checks of one fact disagreeing.
run_test "OB-02" "Core image tag is a pinned HA version from 2026 on" \
  "echo '$CORE_IMAGE' | grep -qE ':20(2[6-9]|[3-9][0-9])\.[0-9]+\.[0-9]+(\.[0-9]+)?$'"

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

# Core's own port for every HTTP check below (80 on 2026.8+, 8123 before) —
# lib/ha_port.sh, ADR-0038. These checks said localhost:8123 until 2026-09-28
# and went red on a device serving the wizard with 200 on :80.
require_ha_port "OB-00"

# --- Wizard redirect (Finding 20 follow-up: BOSv1.2.0 bench regression) ---
# Customer's first browser hit on a fresh GA-provisioned device is
# `http://<device>/` (`:8123` on Core < 2026.8). With GA wizard NOT YET completed, this MUST
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
# We probe `/` the way the device label's QR code hits it, not the way a bare
# `curl /` does. The label encodes `/?pin=<pin>&device=<id>`, and the setup
# panel reads both back out of `window.location` to auto-fill the six digits.
# A redirect that answers with a bare path drops them, so a customer who has
# just scanned the code is still asked to read the PIN off the label and type
# it in — the one thing the QR code exists to avoid. Probing without a query
# string cannot see that at all, which is how it survived unnoticed on every
# device whose redirect worked (OB-WR-03).
_wizard_probe_pin="000000"
_wizard_probe_device="ob-wr-probe"

_wizard_completed=$(jq -r '.data.completed // false' /mnt/data/supervisor/homeassistant/.storage/greenautarky_site 2>/dev/null || echo "false")
_root_redirect=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --connect-timeout 5 \
  "$HA_BASE/?pin=${_wizard_probe_pin}&device=${_wizard_probe_device}" 2>/dev/null)

if [ "$_wizard_completed" = "false" ]; then
  run_test "OB-WR-01" "/ redirects to /greenautarky-setup.html (wizard incomplete)" \
    "echo '$_root_redirect' | grep -qE '^302 .*greenautarky-setup\.html'"

  # Reaching the wizard is necessary but not sufficient. Separate assertion, so
  # a lost PIN reports as a lost PIN instead of hiding inside OB-WR-01 or, worse,
  # passing because OB-WR-01 only ever looked at the status and the path.
  run_test "OB-WR-03" "/ carries the label's ?pin= through to the wizard" \
    "echo '$_root_redirect' | grep -qE 'greenautarky-setup\.html\?.*pin=${_wizard_probe_pin}'"
else
  skip_test "OB-WR-01" "wizard already completed — incomplete-state gate doesn't apply"
  skip_test "OB-WR-03" "wizard already completed — incomplete-state gate doesn't apply"
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

# --- Supervisor plugins come from the DECLARED origin ---
# Which plugins GA builds changes from release to release: T4 (Odoo #708) made
# dns and cli ours; BOSv1.4.0-rc3 added audio, multicast and observer (see its
# gaos_release text in version.yaml). Every such change turned the hard-coded
# split here red although the device was right, so the split is no longer
# written down here at all. It is read from the pinned expectation that
# os_integrity uses (expected.env, generated from the repo's declarations,
# never from the device). This check asserts the ORIGIN — the image repository,
# tag stripped — and OSI-20..24 assert the exact tag. A missing expected.env or
# a plugin that does not run is a FAIL, never a skip.
_OB07_EXP="$SCRIPT_DIR/../os_integrity/expected.env"
# shellcheck source=/dev/null
EXPECTED_PLUGINS=$( [ -s "$_OB07_EXP" ] && . "$_OB07_EXP" && echo "$EXPECTED_PLUGINS")
if [ -z "$EXPECTED_PLUGINS" ]; then
  run_test "OB-07" "Supervisor plugins come from the declared registry (os_integrity/expected.env)" "false"
  printf '        %s missing or carries no EXPECTED_PLUGINS\n' "$_OB07_EXP"
else
  _ob07_n=0
  for pair in $EXPECTED_PLUGINS; do
    _slug="${pair%%=*}"; _ref="${pair#*=}"
    _want="${_ref%:*}"
    _img=$(docker inspect "hassio_${_slug}" --format '{{.Config.Image}}' 2>/dev/null)
    run_test_show "OB-07-${_slug}" "plugin ${_slug} comes from the declared ${_want}" \
      "echo 'running: ${_img:-<not running>}'; [ '${_img%:*}' = '$_want' ]"
    _ob07_n=$((_ob07_n+1))
  done
  run_test "OB-07" "coverage: all five Supervisor plugins checked for origin (${_ob07_n})" \
    "[ $_ob07_n -eq 5 ]"
fi

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
# Same lookup order as ga_manager's auth.get_onboarding_pin(): the canonical
# Core-private secrets store first (.storage/greenautarky_secrets/, dir 0700,
# file 0600 — what ga_manager's identity_write worker writes), then the
# ga-onboarding-pin compat file older provisioning wrote. This check read only
# the compat file and reported a provisioned device as "not provisioned".
# The PIN is never printed: the checks are stat and grep -q, and run_test
# discards output anyway.
HA_CONFIG="/mnt/data/supervisor/homeassistant"
PIN_FILE=""
for _p in "$HA_CONFIG/.storage/greenautarky_secrets/onboarding_pin" "$HA_CONFIG/ga-onboarding-pin"; do
  [ -f "$_p" ] && { PIN_FILE="$_p"; break; }
done
if [ -n "$PIN_FILE" ]; then
  run_test "OB-10a" "PIN file exists (${PIN_FILE#"$HA_CONFIG"/})" "true"
  PERMS=$(stat -c '%a' "$PIN_FILE" 2>/dev/null || echo "?")
  run_test "OB-10b" "PIN file permissions 600" "[ '$PERMS' = '600' ]"
  run_test "OB-10c" "PIN is 6 digits" \
    "grep -qE '^[0-9]{6}$' '$PIN_FILE'"
else
  skip_test "OB-10a" "PIN file" "neither .storage/greenautarky_secrets/onboarding_pin nor ga-onboarding-pin — not provisioned"
fi

# --- Ethernet consent ---
# OB-13: Ethernet consent API endpoint exists
# Judge the STATUS CODE, not curl's exit code. `curl -sf` fails on any non-2xx,
# and a device whose wizard is COMPLETE answers 403 here by design — the step
# may not be re-consented through. So the old form asserted "the endpoint still
# accepts writes", passed only before onboarding, and called a correctly
# finished device a missing endpoint (measured on K31, rc23, 2026-09-07).
# 200 = accepted, 403 = registered and refusing: both prove the view is there.
# A missing view answers 404, and curl answers 000 when nothing listens.
run_test_show "OB-13" "Ethernet consent API view is registered (200 accept or 403 wizard-complete)" \
  "_ob13=\$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 -X POST \
     $HA_BASE/api/greenautarky_site/ethernet \
     -H 'Content-Type: application/json' -d '{\"enable_ethernet\": false}' 2>/dev/null); \
   echo \"HTTP \$_ob13\"; [ \"\$_ob13\" = 200 ] || [ \"\$_ob13\" = 403 ]"

# OB-14: Ethernet is OFF by default — asked of the code that decides it.
# This check used to look for GA_ETHERNET_DISABLED=true in /mnt/data/ga-env.conf
# and skip when that file was absent. Both halves are obsolete: the key was
# inverted to GA_ETHERNET_ENABLED (absent = OFF, so the safe state no longer
# depends on a provisioning step having written anything — see the header of
# ga-manage-ethernet), and /mnt/data/ga-env.conf is only the runtime override;
# it is absent on a device nobody has granted Ethernet to. /etc/ga-env.conf is
# the baked GA_ENV/log/telemetry defaults and carries no Ethernet key at all.
# So the default is a property of ga-manage-ethernet, and that is what is
# asked: with no consent file, no boot marker and no remote marker, `status`
# must answer OFF from source "default". Read-only — `status` writes nothing.
# Whether THIS device's running link matches its consent is the ethernet_force
# suite (ETHF-02..04).
_ob14_none=/nonexistent/ob14
if [ -x /usr/sbin/ga-manage-ethernet ]; then
  run_test_show "OB-14" "Ethernet default without consent or override is OFF (ga-manage-ethernet)" \
    "_s=\$(GA_ENV_FILE=$_ob14_none GA_FORCE_BOOT=$_ob14_none GA_GM_DATA_DIR=$_ob14_none GA_LABEL_FILE=$_ob14_none \
        /usr/sbin/ga-manage-ethernet status 2>/dev/null | grep -E '^ethernet_(enabled|source)='); \
     echo \$_s; echo \"\$_s\" | grep -qx 'ethernet_enabled=false' && echo \"\$_s\" | grep -qx 'ethernet_source=default'"
else
  run_test "OB-14" "Ethernet default without consent or override is OFF (ga-manage-ethernet missing)" "false"
fi

# --- Password reset ---
run_test "PW-01" "Password reset page accessible" \
  "curl -sf --connect-timeout 5 $HA_BASE/greenautarky-password-reset 2>/dev/null | grep -qi 'passwort'"

# The PIN endpoints are RATE LIMITED, and the check one line above deliberately
# trips the limiter — so 429 is a correct answer here and its absence made the
# outcome depend on test order. Same defect, same day, as the Playwright suite's
# users-endpoint check (ha-operating-system#485); this is the sweep that should
# have followed it. 429 proves the view is registered and guarding, which is
# what these two assert.
run_test "PW-02" "Password reset API rejects wrong PIN" \
  "HTTP_CODE=\$(curl -sf --connect-timeout 5 -o /dev/null -w '%{http_code}' \
   -X POST $HA_BASE/api/greenautarky_site/password_reset/users \
   -H 'Content-Type: application/json' -d '{\"pin\": \"000000\"}' 2>/dev/null); \
   [ \"\$HTTP_CODE\" = '401' ] || [ \"\$HTTP_CODE\" = '404' ] || [ \"\$HTTP_CODE\" = '429' ]"

run_test "PW-03" "Password reset API rejects missing fields" \
  "HTTP_CODE=\$(curl -sf --connect-timeout 5 -o /dev/null -w '%{http_code}' \
   -X POST $HA_BASE/api/greenautarky_site/password_reset \
   -H 'Content-Type: application/json' -d '{\"pin\": \"000000\", \"username\": \"\", \"new_password\": \"\"}' 2>/dev/null); \
   [ \"\$HTTP_CODE\" = '400' ] || [ \"\$HTTP_CODE\" = '401' ] || [ \"\$HTTP_CODE\" = '404' ] || [ \"\$HTTP_CODE\" = '429' ]"

suite_end
