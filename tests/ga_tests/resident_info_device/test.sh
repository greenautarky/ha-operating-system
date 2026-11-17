#!/bin/sh
# resident_info_device - the resident's Einstellungen tiles (Odoo #2144 Zigbee list,
# #2145 software versions; greenautarky_site 2.13.0) ON the device.
#
#   GET /api/greenautarky_site/versions       what the device runs, read fresh per request
#   GET /api/greenautarky_site/zigbee_devices Zigbee devices with room, battery, LQI
#
# Always (read-only, no credentials):
#   RIN-01  the installed greenautarky_site is >= 2.13.0 (the version that has the routes)
#   RIN-02  anonymous GET /versions      is refused (401) - registered AND requires auth
#   RIN-03  anonymous GET /zigbee_devices is refused (401)
#   RIN-03c control: an unknown path under the same prefix answers 404, so 401 above really
#           means "route exists, auth required" and not "everything is 401"
#   RIN-04  the data source of /versions, /share/ga_manager/status.json: its ga_release
#           equals /etc/ga-release, and it reports the ga_manager add-on at the version the
#           running container carries (two sources, compared)
# Authorized half - GA_TEST_MINT_TOKEN=1 (it MINTS a credential: one console-login access
# token for the owner, which leaves one refresh token behind; the token stays in this shell
# and is passed to curl via --config on stdin, never on a command line):
#   RIN-10  /versions answers 200: status ok, bundle == /etc/ga-release, the ga_manager
#           add-on at the container's version
#   RIN-11  /zigbee_devices answers 200 with a `devices` array
# Without the flag RIN-10/11 are SKIPPED with the reason (the unauthenticated half above
# still runs). Needs Core up (HA port via lib/ha_port.sh).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Resident Einstellungen tiles: /versions + /zigbee_devices (Odoo #2144, #2145)"

CC_DIR="${GA_RIN_CC_DIR:-/mnt/data/supervisor/homeassistant/custom_components}"
STATUS_FILE="${GA_RIN_STATUS_FILE:-/mnt/data/supervisor/share/ga_manager/status.json}"
RELEASE_FILE="${GA_RIN_RELEASE_FILE:-/etc/ga-release}"
SECRET_FILE="${GA_RIN_SECRET_FILE:-/mnt/data/supervisor/homeassistant/.storage/greenautarky_secrets/console_login_secret}"
GM_SLUG="${GA_RIN_GM_SLUG:-99f1cad4_ga_manager}"
MIN_SITE="2.13.0"

if [ -n "${GA_RIN_BASE:-}" ]; then HA_BASE="$GA_RIN_BASE"; else require_ha_port "RIN-00" || { suite_end; exit 1; }; fi

REL=$(tr -d '[:space:]' < "$RELEASE_FILE" 2>/dev/null)
GM_CTR=$(ga_ctr_exact "$GM_SLUG" 2>/dev/null)
GM_VER=$(docker inspect -f '{{index .Config.Labels "io.hass.version"}}' "$GM_CTR" 2>/dev/null)

SITE_V=$(jq -r '.version // empty' "$CC_DIR/greenautarky_site/manifest.json" 2>/dev/null)
if ga_ver_ge "${SITE_V:-0}" "$MIN_SITE"; then _rc=0; else _rc=1; fi
show_verdict "RIN-01" "greenautarky_site >= $MIN_SITE (has /versions and /zigbee_devices)" "$_rc" "installed: ${SITE_V:-unknown}"

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$HA_BASE$1" 2>/dev/null; }
C1=$(code /api/greenautarky_site/versions)
if [ "$C1" = 401 ]; then _rc=0; else _rc=1; fi
show_verdict "RIN-02" "anonymous GET /api/greenautarky_site/versions is refused (401)" "$_rc" "HTTP $C1 (404 = route missing, 200 = no auth!)"
C2=$(code /api/greenautarky_site/zigbee_devices)
if [ "$C2" = 401 ]; then _rc=0; else _rc=1; fi
show_verdict "RIN-03" "anonymous GET /api/greenautarky_site/zigbee_devices is refused (401)" "$_rc" "HTTP $C2 (404 = route missing, 200 = no auth!)"
C3=$(code /api/greenautarky_site/zz_no_such_route)
if [ "$C3" = 404 ]; then _rc=0; else _rc=1; fi
show_verdict "RIN-03c" "control: an unknown route under the prefix is 404 (so the 401s are real)" "$_rc" "HTTP $C3"

# RIN-04: the status.json /versions reads, against /etc/ga-release and the running container
GMV_FILE=$(jq -r '[.checks[]? | select(.name=="versions.collect") | .details.addons // {} | to_entries[] | select(.key | endswith("_ga_manager")) | .value.version][0] // empty' "$STATUS_FILE" 2>/dev/null)
SREL=$(jq -r '.ga_release // empty' "$STATUS_FILE" 2>/dev/null)
if [ -n "$REL" ] && [ "$SREL" = "$REL" ] && [ -n "$GM_VER" ] && [ "$GMV_FILE" = "$GM_VER" ]; then _rc=0; else _rc=1; fi
show_verdict "RIN-04" "status.json: ga_release == $RELEASE_FILE and ga_manager version == the running container's" "$_rc" "ga_release file='${SREL:-none}' etc='${REL:-none}'; gm status.json='${GMV_FILE:-none}' container='${GM_VER:-none}'"

# ---------------------------------------------------------------- authorized half
if [ "${GA_TEST_MINT_TOKEN:-0}" != 1 ]; then
  skip_test "RIN-10" "/versions answers an authorized user" "mints a credential - run with GA_TEST_MINT_TOKEN=1 (canary)"
  skip_test "RIN-11" "/zigbee_devices answers an authorized user" "mints a credential - run with GA_TEST_MINT_TOKEN=1 (canary)"
else
  # console-login signed token (the same mechanism e2e_user_flows CON-02 proves): the server
  # HMACs the RAW payload JSON with the decoded secret. Without `sub` it logs in the owner.
  b64url() { base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '='; }
  TOKEN=""
  if [ -r "$SECRET_FILE" ]; then
    EXP=$(( $(date +%s) + 60 ))
    PJ="{\"exp\":${EXP},\"nonce\":\"$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')\"}"
    PB=$(printf '%s' "$PJ" | b64url)
    SN=$(tr '_-' '/+' < "$SECRET_FILE" | tr -d '\n')
    case $(( (4 - ${#SN} % 4) % 4 )) in 1) PAD="=" ;; 2) PAD="==" ;; 3) PAD="===" ;; *) PAD="" ;; esac
    SH=$(printf '%s%s' "$SN" "$PAD" | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n')
    SG=$(printf '%s' "$PJ" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$SH" -binary 2>/dev/null | b64url)
    HTML=$(curl -s --max-time 20 "$HA_BASE/api/ga_remote_login?t=$PB&s=$SG" 2>/dev/null)
    TOKEN=$(printf '%s' "$HTML" | sed -n "s/.*access_token[\"']:[ ]*[\"']\\([^\"']*\\).*/\\1/p" | head -1)
  fi
  api() {   # api <path> -> body on stdout; token via --config on stdin, never an argument
    printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -s --max-time 30 --config - "$HA_BASE$1"
  }
  if [ -z "$TOKEN" ]; then
    show_verdict "RIN-10" "/versions answers an authorized user" 1 "could not mint a console-login token (secret readable: $([ -r "$SECRET_FILE" ] && echo yes || echo no))"
    show_verdict "RIN-11" "/zigbee_devices answers an authorized user" 1 "no token"
  else
    V=$(api /api/greenautarky_site/versions)
    VS=$(printf '%s' "$V" | jq -r '.status // empty' 2>/dev/null)
    VB=$(printf '%s' "$V" | jq -r '.bundle // empty' 2>/dev/null)
    VG=$(printf '%s' "$V" | jq -r '[.components[]? | select(.group=="addon" and (.id | endswith("_ga_manager"))) | .version][0] // empty' 2>/dev/null)
    if [ "$VS" = ok ] && [ "$VB" = "$REL" ] && [ -n "$GM_VER" ] && [ "$VG" = "$GM_VER" ]; then _rc=0; else _rc=1; fi
    show_verdict "RIN-10" "/versions: status ok, bundle == $RELEASE_FILE, ga_manager == the container's version" "$_rc" "status=${VS:-none} bundle='${VB:-none}' (etc: '${REL:-none}') gm='${VG:-none}' (container: '${GM_VER:-none}')"
    Z=$(api /api/greenautarky_site/zigbee_devices)
    if printf '%s' "$Z" | jq -e '.devices | type == "array"' >/dev/null 2>&1; then _rc=0; else _rc=1; fi
    show_verdict "RIN-11" "/zigbee_devices answers 200 with a devices array" "$_rc" "$(printf '%s' "$Z" | jq -c '{devices: (.devices | length)}' 2>/dev/null || echo 'not JSON')"
  fi
fi

suite_end
