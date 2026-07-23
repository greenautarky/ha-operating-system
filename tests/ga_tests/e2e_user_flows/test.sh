#!/bin/sh
# tests/ga_tests/e2e_user_flows/test.sh — on-device E2E user-facing flow tests.
#
# Runs ON the device. Exercises the six user-facing flows that the manual
# K31 reflash-and-click verifies today:
#
#   1. HA stock onboarding   (POST /api/onboarding/users, /core_config, /integration)
#   2. Login via /auth/token (long-lived-token / regular token exchange)
#   3. Lovelace dashboard with all 14 ga_frontend_bundle cards
#   4. greenautarky_site wizard (simulated state from ga_manager step 9)
#   5. Password-forgotten via PIN
#   6. Console-login signed-token auto-login
#
# Each step is independent — if step N fails, the remaining ones still run.
#
# Designed to run inside ga-bootstrap-aware containers (no Zigbee, no real
# entities) — uses synthetic input_number / input_boolean helpers so card
# rendering can be exercised without paired hardware.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPERS="$SCRIPT_DIR/../lib/test_helpers.sh"
if [ -f "$HELPERS" ]; then
  . "$HELPERS"
else
  # Minimal helpers if running standalone (= not through run_all.sh on-device)
  PASS=0
  FAIL=0
  SKIP=0
  _pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
  _fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
  _skip() { echo "  SKIP  $1: $2"; SKIP=$((SKIP+1)); }
  suite_start() { echo "--- $1 ---"; }
  suite_end() { echo "=== Tests: $PASS passed, $FAIL failed, $SKIP skipped ==="; [ "$FAIL" -eq 0 ]; }
fi

suite_start "User flows (onboarding + login + dashboard + wizard + password-reset + console-login)"

HA="http://localhost:8123"
CFG_DIR="/mnt/data/supervisor/homeassistant"
STORAGE_DIR="${CFG_DIR}/.storage"
STATE_FILE="${STORAGE_DIR}/greenautarky_site"
GA_SECRETS_DIR="${STORAGE_DIR}/greenautarky_secrets"
BUNDLE_COMMUNITY="${CFG_DIR}/custom_components/ga_frontend_bundle/community"
# greenautarky_site v1.0.3 moved the PIN file from /config/ga-onboarding-pin
# to /config/.storage/greenautarky_secrets/onboarding_pin (= same .storage/
# dir already used since v1.0.1 for the console-login secret). Test writes
# the new path; integration's _migrate_legacy_pin handles devices upgrading
# from older versions.
PIN_FILE="${GA_SECRETS_DIR}/onboarding_pin"
CONSOLE_LOGIN_SECRET_FILE="${GA_SECRETS_DIR}/console_login_secret"
TEST_USER_NAME="e2etestadmin"
# Deterministic so re-runs can re-login (= no $$ randomness)
TEST_USER_PASS="e2e-test-pw-fixed-2026"
TEST_PIN="123456"
TOKEN=""

# ===========================================================================
# 0. Test fixtures — write all required state files BEFORE any test runs so
#    DASH-02 (which toggles `completed`) and WIZ-* can both read/write them.
# ===========================================================================
mkdir -p "$STORAGE_DIR"
# ALWAYS reset to a clean wizard-pending state at the start of each run —
# tests assert completed=false (PWRST, WIZ) AND need a known baseline to
# restore to after DASH-02 (which flips completed=true).
printf '%s' '{"version":2,"key":"greenautarky_site","data":{"completed":false,"tenant_mode":true,"steps_done":[],"consents":{}}}' \
  > "$STATE_FILE"
mkdir -p "$GA_SECRETS_DIR"
chmod 0700 "$GA_SECRETS_DIR"
# PIN now under $GA_SECRETS_DIR (v1.0.3+). $GA_SECRETS_DIR was mkdir'd above.
[ -f "$PIN_FILE" ] || { printf '%s' "$TEST_PIN" > "$PIN_FILE"; chmod 0600 "$PIN_FILE"; }
if [ ! -f "$CONSOLE_LOGIN_SECRET_FILE" ]; then
  head -c 32 /dev/urandom | base64 | tr -d '\n=' > "$CONSOLE_LOGIN_SECRET_FILE"
  chmod 0600 "$CONSOLE_LOGIN_SECRET_FILE"
fi

# ===========================================================================
# 1. HA stock onboarding
# ===========================================================================

ha_onboarding_status() {
  curl -s "$HA/api/onboarding" 2>/dev/null
}

# ONBOARD-01 — also detect re-run case (= user step already done OR all
# stock onboarding done so /api/onboarding 404s).
status=$(ha_onboarding_status)
user_done=$(echo "$status" | jq -r '.[] | select(.step=="user") | .done' 2>/dev/null)
if [ "$user_done" = "false" ]; then
  _pass "ONBOARD-01: HA onboarding 'user' step pending"
  ONBOARDING_FRESH=1
elif [ "$user_done" = "true" ] || echo "$status" | grep -q "404"; then
  _pass "ONBOARD-01: HA onboarding already completed (re-run mode — fixed-creds login path)"
  ONBOARDING_FRESH=0
else
  _fail "ONBOARD-01: cannot determine onboarding state — response: $status"
  ONBOARDING_FRESH=0
fi

if [ "$ONBOARDING_FRESH" = "1" ]; then
  # Fresh device — create user via /api/onboarding/users.
  create_resp=$(curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"client_id\":\"$HA/\",\"name\":\"$TEST_USER_NAME\",\"username\":\"$TEST_USER_NAME\",\"password\":\"$TEST_USER_PASS\",\"language\":\"en\"}" \
    "$HA/api/onboarding/users" 2>/dev/null)

  AUTH_CODE=$(echo "$create_resp" | jq -r '.auth_code // empty' 2>/dev/null)
  if [ -n "$AUTH_CODE" ]; then
    _pass "ONBOARD-02: created admin user, received auth_code"
  else
    _fail "ONBOARD-02: no auth_code in response — $create_resp"
  fi

  # ONBOARD-03: exchange auth_code for access_token via /auth/token
  token_resp=$(curl -s -X POST -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=authorization_code&code=$AUTH_CODE&client_id=$HA/" \
    "$HA/auth/token" 2>/dev/null)

  if echo "$token_resp" | jq -e '.access_token | length > 50' >/dev/null 2>&1; then
    TOKEN=$(echo "$token_resp" | jq -r '.access_token')
    _pass "ONBOARD-03: exchanged auth_code for access_token"
  else
    _fail "ONBOARD-03: auth_code → token exchange failed — $token_resp"
  fi
else
  # Re-run mode — onboarding already done. Walk the HA login_flow with the
  # known fixed credentials to obtain a fresh token.
  flow_resp=$(curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"client_id\":\"$HA/\",\"handler\":[\"homeassistant\",null],\"redirect_uri\":\"$HA/?auth_callback=1\"}" \
    "$HA/auth/login_flow" 2>/dev/null)
  FLOW_ID=$(echo "$flow_resp" | jq -r '.flow_id // empty' 2>/dev/null)

  if [ -n "$FLOW_ID" ]; then
    step_resp=$(curl -s -X POST -H "Content-Type: application/json" \
      -d "{\"client_id\":\"$HA/\",\"username\":\"$TEST_USER_NAME\",\"password\":\"$TEST_USER_PASS\"}" \
      "$HA/auth/login_flow/$FLOW_ID" 2>/dev/null)
    AUTH_CODE=$(echo "$step_resp" | jq -r '.result // empty' 2>/dev/null)
    if [ -n "$AUTH_CODE" ]; then
      _pass "ONBOARD-02: re-login flow returned auth_code (fixed-creds path)"
      token_resp=$(curl -s -X POST -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=authorization_code&code=$AUTH_CODE&client_id=$HA/" \
        "$HA/auth/token" 2>/dev/null)
      if echo "$token_resp" | jq -e '.access_token | length > 50' >/dev/null 2>&1; then
        TOKEN=$(echo "$token_resp" | jq -r '.access_token')
        _pass "ONBOARD-03: re-login → auth_code → token (fixed-creds path)"
      else
        _fail "ONBOARD-03: token exchange failed (re-run) — $token_resp"
      fi
    else
      _fail "ONBOARD-02: re-login flow_id step returned no auth_code — $step_resp"
    fi
  else
    _fail "ONBOARD-02: /auth/login_flow returned no flow_id — $flow_resp"
  fi
fi

# ===========================================================================
# 2. Login
# ===========================================================================

# LOGIN-01: HA's actual login flow is a two-step OAuth dance — POST
# username+password to /auth/login_flow to get a flow_id, then POST again
# to advance. For test purposes we already have the token from ONBOARD-03.
# Confirm the token is non-empty as the LOGIN flow proxy.
if [ -n "$TOKEN" ] && [ "${#TOKEN}" -gt 50 ]; then
  _pass "LOGIN-01: have valid token from onboarding (HA uses OAuth login_flow not grant_type=password)"
else
  _fail "LOGIN-01: no token available — login flow can't proceed"
fi

# LOGIN-02: authenticated /api/states
if [ -n "$TOKEN" ] && curl -s -H "Authorization: Bearer $TOKEN" "$HA/api/states" | jq -e 'type=="array"' >/dev/null 2>&1; then
  _pass "LOGIN-02: GET /api/states returns valid JSON array (authenticated)"
else
  _fail "LOGIN-02: GET /api/states failed authenticated"
fi

# ===========================================================================
# 3. Lovelace dashboard render — 14 ga_frontend_bundle cards
# ===========================================================================

if [ ! -f "${BUNDLE_COMMUNITY}/cards.json" ]; then
  _skip "DASH-01" "cards.json not found at ${BUNDLE_COMMUNITY}"
else
  N=$(jq '.cards | length' "${BUNDLE_COMMUNITY}/cards.json")
  HITS=0
  jq -r '.cards[] | "\(.id)/\(.file)"' "${BUNDLE_COMMUNITY}/cards.json" | while IFS= read -r card_path; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "${HA}/ga_frontend_bundle_static/${card_path}")
    if [ "$code" = "200" ]; then
      printf '  ok   %s\n' "$card_path"
    else
      printf '  miss %s (%s)\n' "$card_path" "$code"
    fi
  done
  # Re-count in subshell-safe way (the while loop ran in subshell — pipe creates one)
  HITS=$(jq -r '.cards[] | "\(.id)/\(.file)"' "${BUNDLE_COMMUNITY}/cards.json" | while IFS= read -r card_path; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "${HA}/ga_frontend_bundle_static/${card_path}")
    [ "$code" = "200" ] && echo 1
  done | wc -l)
  if [ "$HITS" -eq "$N" ]; then
    _pass "DASH-01: all $N ga_frontend_bundle cards return HTTP 200"
  else
    _fail "DASH-01: only $HITS/$N cards return HTTP 200"
  fi
fi

# DASH-02: card JS module URLs appear in served HTML. Two layers of
# "are we through onboarding?" must be cleared first:
#   1. HA stock onboarding has THREE steps after `user` (core_config,
#      analytics, integration) — until ALL are done the served index is
#      the onboarding shell, NO custom-integration extra-module URLs.
#   2. greenautarky_site monkey-patches HA's IndexView.get to
#      redirect to /greenautarky-setup until `state.completed == true`.
#
# Mark BOTH as complete, then probe. SAVE_STATE restores the greenautarky
# state at the end so subsequent WIZ-/PWRST- tests still see the
# wizard-incomplete state they expect.
SAVE_STATE=$(cat "$STATE_FILE" 2>/dev/null)
jq '.data.completed=true' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

# Complete the remaining HA stock onboarding steps (idempotent). The
# integration step requires redirect_uri AND client_id; the others ignore
# extra keys so we pass {} where empty would be parsed.
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{}' "$HA/api/onboarding/core_config" >/dev/null 2>&1
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{}' "$HA/api/onboarding/analytics" >/dev/null 2>&1
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"client_id\":\"$HA/\",\"redirect_uri\":\"$HA/?auth_callback=1\"}" \
  "$HA/api/onboarding/integration" >/dev/null 2>&1

ha core restart --no-progress >/dev/null 2>&1
# Wait until ga_frontend_bundle is loaded — /api/states 200 is not enough,
# it can return before custom_components finish their async_setup. Poll
# /api/config until DOMAIN appears in components, up to 180 s.
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
  sleep 10
  comp=$(curl -s -H "Authorization: Bearer $TOKEN" "$HA/api/config" 2>/dev/null \
         | jq -r '.components // [] | join(",")' 2>/dev/null)
  echo "$comp" | tr ',' '\n' | grep -qx ga_frontend_bundle && break
done

# Re-acquire token because Core restart invalidates the previous one.
flow_id=$(curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"client_id\":\"$HA/\",\"handler\":[\"homeassistant\",null],\"redirect_uri\":\"$HA/?auth_callback=1\"}" \
  "$HA/auth/login_flow" 2>/dev/null | jq -r '.flow_id // empty')
if [ -n "$flow_id" ]; then
  ac=$(curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"client_id\":\"$HA/\",\"username\":\"$TEST_USER_NAME\",\"password\":\"$TEST_USER_PASS\"}" \
    "$HA/auth/login_flow/$flow_id" 2>/dev/null | jq -r '.result // empty')
  if [ -n "$ac" ]; then
    DASH_TOK=$(curl -s -X POST -d "grant_type=authorization_code&code=$ac&client_id=$HA/" \
      "$HA/auth/token" 2>/dev/null | jq -r '.access_token // empty')
  fi
fi
[ -z "${DASH_TOK:-}" ] && DASH_TOK="$TOKEN"
N_HTML=$(curl -sL -H "Authorization: Bearer $DASH_TOK" "$HA/" 2>/dev/null \
  | grep -oE '/ga_frontend_bundle_static/[^"]+' | sort -u | wc -l)
N_CARDS=$(jq '.cards | length' "${BUNDLE_COMMUNITY}/cards.json" 2>/dev/null || echo 0)
if [ "$N_HTML" -ge "$N_CARDS" ] && [ "$N_CARDS" -gt 0 ]; then
  _pass "DASH-02: served HTML lists $N_HTML card URLs (≥ $N_CARDS expected) after wizard-completed bypass"
else
  _fail "DASH-02: only $N_HTML URLs in HTML (expected ≥ $N_CARDS) — ga_frontend_bundle add_extra_js_url not effective"
fi
# Restore wizard-incomplete state for subsequent tests (PIN, wizard).
printf '%s' "$SAVE_STATE" > "$STATE_FILE"
ha core restart --no-progress >/dev/null 2>&1
# Same waiting-for-component pattern as DASH-02: /api/states is not enough,
# the greenautarky_site setup must finish to honor the restored state.
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
  sleep 10
  comp=$(curl -s -H "Authorization: Bearer $TOKEN" "$HA/api/config" 2>/dev/null \
         | jq -r '.components // [] | join(",")' 2>/dev/null)
  echo "$comp" | tr ',' '\n' | grep -qx greenautarky_site && break
done

# DASH-03 — ga_frontend_bundle async_setup actually fired. The integration
# is yaml-only with integration_type="service"; HA Core 2025.11.x silently
# skips async_setup unless CONFIG_SCHEMA is declared. If async_setup never
# ran, none of the cards are injected via add_extra_js_url and dashboards
# using custom:mushroom-card etc. fail with "unknown card type".
#
# Check hass.config.components via /api/config — the integration's DOMAIN
# must appear in the loaded-components list.
loaded=$(curl -s -H "Authorization: Bearer $TOKEN" "$HA/api/config" 2>/dev/null \
  | jq -r '.components // [] | join(",")' 2>/dev/null)
if echo "$loaded" | tr ',' '\n' | grep -qx ga_frontend_bundle; then
  _pass "DASH-03: ga_frontend_bundle integration loaded (in hass.config.components)"
else
  _fail "DASH-03: ga_frontend_bundle NOT in hass.config.components — async_setup did not fire (CONFIG_SCHEMA missing?)"
fi

# DASH-04 — greenautarky_site integration actually fired.
if echo "$loaded" | tr ',' '\n' | grep -qx greenautarky_site; then
  _pass "DASH-04: greenautarky_site integration loaded"
else
  _fail "DASH-04: greenautarky_site NOT in hass.config.components"
fi

# ===========================================================================
# 4. greenautarky_site wizard (simulated state from converge step 9)
# ===========================================================================

# WIZ-01: write state file to ARM the wizard. STORAGE_VERSION must match
# what the integration expects (= 2 as of 1.0.1). Writing a wrong version
# would trigger HA's storage migrator and the base _async_migrate_func
# raises NotImplementedError (= what we'd see if a v1 file ever existed).
# Wipe any prior version-mismatched file so the test is self-healing.
mkdir -p "$STORAGE_DIR"
NEED_WRITE=1
if [ -f "$STATE_FILE" ]; then
  cur_ver=$(jq -r '.version // 0' "$STATE_FILE" 2>/dev/null)
  [ "$cur_ver" = "2" ] && NEED_WRITE=0
fi
if [ "$NEED_WRITE" = "1" ]; then
  printf '%s' '{"version":2,"key":"greenautarky_site","data":{"completed":false,"tenant_mode":true,"steps_done":[],"consents":{}}}' \
    > "$STATE_FILE"
fi
if [ -f "$STATE_FILE" ]; then
  _pass "WIZ-01: greenautarky_site state file present (version=$(jq -r .version $STATE_FILE))"
else
  _fail "WIZ-01: could not write greenautarky_site state"
fi

# WIZ-02: PIN file present (gates password reset)
[ -f "$PIN_FILE" ] || { printf '%s' "$TEST_PIN" > "$PIN_FILE"; chmod 0600 "$PIN_FILE"; }
if [ -f "$PIN_FILE" ]; then
  _pass "WIZ-02: onboarding_pin file present at $PIN_FILE (= $(wc -c < $PIN_FILE) bytes)"
else
  _fail "WIZ-02: could not write PIN file"
fi

# Restart HA Core so the new state file is picked up.
ha core restart --no-progress >/dev/null 2>&1
# Wait until /api/states works again
WAIT=0
while [ $WAIT -lt 90 ]; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$HA/api/states" 2>/dev/null)
  [ "$code" = "200" ] && break
  sleep 5
  WAIT=$((WAIT+5))
done
echo "  (Core restart took ${WAIT}s)"

# WIZ-03: greenautarky onboarding status endpoint (actual URL is /api/greenautarky_site/status)
status=$(curl -s -H "Authorization: Bearer $TOKEN" "$HA/api/greenautarky_site/status" 2>/dev/null)
if echo "$status" | jq -e 'has("completed") or has("tenant_mode")' >/dev/null 2>&1; then
  _pass "WIZ-03: /api/greenautarky_site/status returns valid state: $(echo "$status" | jq -c)"
else
  _fail "WIZ-03: /api/greenautarky_site/status invalid — response: $status"
fi

# WIZ-04: wizard frontend at /greenautarky-setup (no .html suffix)
code=$(curl -sL -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$HA/greenautarky-setup" 2>/dev/null)
if [ "$code" = "200" ]; then
  _pass "WIZ-04: /greenautarky-setup served (HTTP 200)"
else
  _fail "WIZ-04: /greenautarky-setup HTTP $code"
fi

# ===========================================================================
# 5. Password-forgotten via PIN
# ===========================================================================

# PWRST-01: correct PIN accepted at /api/greenautarky_site/verify_pin
# verify_pin is idempotent — once verified, ANY subsequent call returns
# {"status":"ok"}. To test the wrong-PIN-rejected case (PWRST-02) we
# reset pin_verified=false in storage between calls.
pin_reset() {
  jq '.data.pin_verified=false | .data.pin_attempts=0 | .data.pin_locked_until=null' \
    "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null && mv "$STATE_FILE.tmp" "$STATE_FILE"
  ha core restart --no-progress >/dev/null 2>&1
  for i in 1 2 3 4 5 6; do
    sleep 10
    curl -s -o /dev/null -H "Authorization: Bearer $TOKEN" "$HA/api/states" 2>/dev/null && break
  done
}

pin_reset
resp=$(curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"pin\":\"$TEST_PIN\"}" "$HA/api/greenautarky_site/verify_pin" 2>/dev/null)
if echo "$resp" | jq -e '.status == "ok"' >/dev/null 2>&1; then
  _pass "PWRST-01: verify_pin accepts correct PIN (status=ok)"
else
  _fail "PWRST-01: verify_pin rejected correct PIN — response: $resp"
fi

pin_reset
resp=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"pin":"000000"}' "$HA/api/greenautarky_site/verify_pin" 2>/dev/null)
# Reject = status NOT ok (could be {"status":"error"} or {"error":"..."} or 401)
if echo "$resp" | jq -e '.status != "ok"' >/dev/null 2>&1; then
  _pass "PWRST-02: verify_pin rejects wrong PIN — response: $resp"
else
  _fail "PWRST-02: wrong PIN was accepted (security regression!) — response: $resp"
fi

# ===========================================================================
# 6. Console-login signed-token auto-login
# ===========================================================================

# CON-01: HMAC secret file at v1.0.1+ path
mkdir -p "$GA_SECRETS_DIR"
chmod 0700 "$GA_SECRETS_DIR"
if [ ! -f "$CONSOLE_LOGIN_SECRET_FILE" ]; then
  head -c 32 /dev/urandom | base64 | tr -d '\n=' > "$CONSOLE_LOGIN_SECRET_FILE"
  chmod 0600 "$CONSOLE_LOGIN_SECRET_FILE"
fi
perms=$(stat -c '%a' "$CONSOLE_LOGIN_SECRET_FILE" 2>/dev/null || stat -f '%Lp' "$CONSOLE_LOGIN_SECRET_FILE" 2>/dev/null)
if [ "$perms" = "600" ]; then
  _pass "CON-01: console-login HMAC secret at $CONSOLE_LOGIN_SECRET_FILE (0600)"
else
  _fail "CON-01: console-login secret perms $perms (expected 600)"
fi

# CON-02: mint a token + sign properly. The server decodes `t` from
# base64url to get the original JSON bytes, then HMAC's those raw bytes —
# so we must sign the RAW JSON, NOT the base64-encoded form.
NONCE_HEX=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
EXP=$(( $(date +%s) + 60 ))
PAYLOAD_JSON="{\"exp\":${EXP},\"nonce\":\"${NONCE_HEX}\",\"sub\":\"${TEST_USER_NAME}\"}"
b64url() { base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '='; }
PAYLOAD_B64=$(printf '%s' "$PAYLOAD_JSON" | b64url)
# The server _read_console_secret decodes the stored secret (hex or base64url)
# back to raw bytes IF the decoded length >= 32. So we must decode here too
# and use the raw bytes as the HMAC key, NOT the encoded string.
SECRET_STR=$(cat "$CONSOLE_LOGIN_SECRET_FILE")
# base64url → standard base64 (swap -_ for +/) then add trailing '=' padding,
# then base64 -d, then hex-encode. Padding MUST be at END, not start.
add_b64_pad() {
  local s="$1"; local n=${#s}; local pad=$(( (4 - n % 4) % 4 ))
  local i; local p=""
  for i in $(seq 1 $pad); do p="${p}="; done
  printf '%s%s' "$s" "$p"
}
SECRET_NORM=$(printf '%s' "$SECRET_STR" | tr '_-' '/+')
SECRET_PAD=$(add_b64_pad "$SECRET_NORM")
SECRET_HEX=$(printf '%s' "$SECRET_PAD" | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n')
SIG_B64=$(printf '%s' "$PAYLOAD_JSON" \
          | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$SECRET_HEX" -binary 2>/dev/null \
          | b64url)

if [ -n "$PAYLOAD_B64" ] && [ -n "$SIG_B64" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' "$HA/api/ga_remote_login?t=$PAYLOAD_B64&s=$SIG_B64")
  if [ "$code" = "200" ] || [ "$code" = "302" ]; then
    _pass "CON-02: /api/ga_remote_login accepts freshly-minted signed token (HTTP $code)"
  else
    _fail "CON-02: /api/ga_remote_login rejected valid token (HTTP $code)"
  fi
else
  _skip "CON-02" "could not mint signed token (openssl + base64 missing?)"
fi

suite_end
