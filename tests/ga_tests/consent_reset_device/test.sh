#!/bin/sh
# consent_reset_device - an onboarding reset leaves NO telemetry decision on the device (TEL-54).
#
# After a reset nobody has decided: no stored record, no tier marker, as on a freshly flashed
# device. Expected RED on images with greenautarky-site < 2.16.0 / greenautarky-telemetry < 0.2.5,
# where the reset recorded the starting values (tier 1 "accepted") and the tier-1 marker came back.
#
# DESTRUCTIVE (GA_TEST_DESTRUCTIVE=1, canary only): it records a decision and RESETS the
# onboarding - the wizard has to be walked again afterwards. It also mints one console-login
# token (one refresh token left behind); the token stays in this shell, passed on stdin only.
#
#   TEL-54a  a decision recorded over the websocket (tier1 off, tier2 on) reaches the device:
#            stored record + tier-2 marker, no tier-1 marker (the refresh unit works on write)
#   TEL-54b  the reset answers 200 with telemetry_reset "cleared"
#   TEL-54c  no stored record afterwards
#   TEL-54d  the component reports no decision (policy_version_accepted null)
#   TEL-54e  no tier marker (new or legacy names) within GA_TEL54_WAIT seconds
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Onboarding reset forgets the telemetry decision (TEL-54)"

STORE="${GA_TEL54_STORE:-/mnt/data/supervisor/homeassistant/.storage/greenautarky_telemetry}"
MARKERS="${GA_TEL54_MARKER_DIR:-/mnt/data}"
SECRET_FILE="${GA_TEL54_SECRET_FILE:-/mnt/data/supervisor/homeassistant/.storage/greenautarky_secrets/console_login_secret}"
WAIT="${GA_TEL54_WAIT:-60}"
CORE="${GA_TEL54_CORE:-homeassistant}"
IDS="TEL-54a TEL-54b TEL-54c TEL-54d TEL-54e"

if ! ga_destructive "TEL-54" "onboarding reset forgets the telemetry decision"; then
  for i in $IDS; do skip_test "$i" "part of TEL-54" "destructive - runs only with GA_TEST_DESTRUCTIVE=1"; done
  suite_end; exit 0
fi
if [ -n "${GA_TEL54_BASE:-}" ]; then HA_BASE="$GA_TEL54_BASE"; else require_ha_port "TEL-54-00" || { suite_end; exit 1; }; fi

# console-login token for the owner (same mechanism as resident_info_device RIN-10)
b64url() { base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '='; }
TOKEN=""
if [ -r "$SECRET_FILE" ]; then
  PJ="{\"exp\":$(( $(date +%s) + 60 )),\"nonce\":\"tel54-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')\"}"
  SN=$(tr '_-' '/+' < "$SECRET_FILE" | tr -d '\n')
  case $(( (4 - ${#SN} % 4) % 4 )) in 1) PAD="=" ;; 2) PAD="==" ;; 3) PAD="===" ;; *) PAD="" ;; esac
  SH=$(printf '%s%s' "$SN" "$PAD" | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n')
  SG=$(printf '%s' "$PJ" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$SH" -binary 2>/dev/null | b64url)
  TOKEN=$(curl -s --max-time 20 "$HA_BASE/api/ga_remote_login?t=$(printf '%s' "$PJ" | b64url)&s=$SG" 2>/dev/null \
    | sed -n "s/.*access_token[\"']:[ ]*[\"']\\([^\"']*\\).*/\\1/p" | head -1)
fi
if [ -z "$TOKEN" ]; then
  for i in $IDS; do show_verdict "$i" "part of TEL-54" 1 "no console-login token (secret readable: $([ -r "$SECRET_FILE" ] && echo yes || echo no)) - nothing was changed"; done
  suite_end; exit 1
fi

# One websocket command inside the Core container (it has aiohttp). Token and command on stdin.
WS_PY='import asyncio,json,sys,aiohttp
tok,port,cmd=sys.stdin.read().split("\n",2)
async def go():
  async with aiohttp.ClientSession() as s:
    async with s.ws_connect("http://127.0.0.1:%s/api/websocket"%port) as w:
      await w.receive_json(); await w.send_json({"type":"auth","access_token":tok})
      if (await w.receive_json()).get("type")!="auth_ok": print("{\"auth\":false}"); return
      await w.send_json({"id":1,**json.loads(cmd)}); r=await w.receive_json()
      print(json.dumps(r.get("result") if r.get("success") else {"error":r.get("error")}))
asyncio.run(go())'
ws() { printf '%s\n%s\n%s' "$TOKEN" "${HA_BASE##*:}" "$1" | docker exec -i "$CORE" python3 -c "$WS_PY" 2>/dev/null; }
markers() { for m in .ga-consent-tier1 .ga-consent-tier2 .ga-consent-error_logs .ga-consent-metrics; do [ -e "$MARKERS/$m" ] && printf '%s ' "$m"; done; }
wait_until() { _t=0; while [ "$_t" -lt "$WAIT" ]; do eval "$1" && return 0; sleep 2; _t=$((_t + 2)); done; eval "$1"; }

# TEL-54a: a real decision, the non-default one, through the component's own command
SET=$(ws '{"type":"greenautarky_telemetry/set","tier1":false,"tier2":true}')
wait_until '[ -s "$STORE" ] && [ -e "$MARKERS/.ga-consent-tier2" ] && [ ! -e "$MARKERS/.ga-consent-tier1" ]'; _rc=$?
show_verdict "TEL-54a" "a recorded decision reaches the device (record + tier-2 marker, no tier-1 marker)" "$_rc" "set: $(printf '%s' "$SET" | head -c 120); markers: $(markers)"

# TEL-54b: the reset
R=$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -s --max-time 60 --config - -X POST -w '\n%{http_code}' "$HA_BASE/api/greenautarky_site/reset")
C=$(printf '%s\n' "$R" | tail -n 1); B=$(printf '%s\n' "$R" | sed '$d')
if [ "$C" = 200 ] && [ "$(printf '%s' "$B" | jq -r '.telemetry_reset // empty' 2>/dev/null)" = cleared ]; then _rc=0; else _rc=1; fi
show_verdict "TEL-54b" "the reset answers 200 telemetry_reset=cleared" "$_rc" "HTTP $C $(printf '%s' "$B" | head -c 160)"

# TEL-54c..e: nobody has decided any more
wait_until '[ ! -e "$STORE" ]'; _rc=$?
show_verdict "TEL-54c" "no stored telemetry record after the reset" "$_rc" "$([ -e "$STORE" ] && head -c 200 "$STORE" || echo 'absent')"
G=$(ws '{"type":"greenautarky_telemetry/get"}')
if [ "$(printf '%s' "$G" | jq -r 'if has("policy_version_accepted") then (.policy_version_accepted|tostring) else "missing" end' 2>/dev/null)" = null ]; then _rc=0; else _rc=1; fi
show_verdict "TEL-54d" "the component reports no decision (policy_version_accepted null)" "$_rc" "$(printf '%s' "$G" | head -c 200)"
wait_until '[ -z "$(markers)" ]'; _rc=$?
show_verdict "TEL-54e" "no tier marker within ${WAIT}s (the refresh unit reacts to the removal)" "$_rc" "left: $(markers)"

suite_end
