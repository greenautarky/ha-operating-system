#!/bin/sh
# Host-side selftest of resident_info_device/test.sh: the LIVE suite against a stub Core
# (curl) and stub docker. Known-good must PASS; each broken state (route missing = 404, an
# endpoint answering anonymous users, wrong release, wrong gm version, site too old, no token
# minted, an answer that is not a devices array) must FAIL on the named check; the authorized
# half must SKIP without GA_TEST_MINT_TOKEN and must never put the token on a command line.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/devsuite_selftest.sh"
ds_init
F="$W/f"; CC="$W/cc"; mkdir -p "$F" "$CC/greenautarky_site" "$W/share" "$W/sec"
GMV=0.277.7

cat > "$W/bin/docker" <<'STUB'
#!/bin/sh
case "$*" in
  *io.hass.version*) cat "$FAKE/gm_version" ;;
  inspect*) echo true ;;
  ps*) echo app_99f1cad4_ga_manager ;;
esac
STUB
# a Core: HTTP status per path from $FAKE/code.<name>; the console-login page; the API bodies
cat > "$W/bin/curl" <<'STUB'
#!/bin/sh
# record every curl command line: the token must never be on one
echo "$*" >> "$FAKE/curl.lines"
url=""; cfg=0; wcode=0
for a in "$@"; do case "$a" in http*) url="$a" ;; --config) cfg=1 ;; %\{http_code\}|*http_code*) wcode=1 ;; esac; done
name=$(echo "$url" | sed 's|.*/||; s|?.*||')
if [ "$wcode" = 1 ]; then cat "$FAKE/code.$name" 2>/dev/null || echo 404; exit 0; fi
case "$name" in
  ga_remote_login)
    # the server side of the console-login: decode t, HMAC the RAW payload with the decoded secret, compare s
    t=$(echo "$url" | sed 's/.*[?&]t=\([^&]*\).*/\1/'); sg=$(echo "$url" | sed 's/.*[?&]s=\([^&]*\).*/\1/')
    dec() { _x=$(printf '%s' "$1" | tr '_-' '/+'); case $(( ${#_x} % 4 )) in 1) _x="$_x=" ;; 2) _x="$_x==" ;; 3) _x="$_x===" ;; esac; printf '%s' "$_x" | base64 -d 2>/dev/null; }
    kh=$(dec "$(cat "$(cat "$FAKE/secret_file")")" | od -An -tx1 | tr -d ' \n')
    want=$(dec "$t" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$kh" -binary | base64 -w0 | tr '+/' '-_' | tr -d '=')
    if [ -f "$FAKE/no_token" ] || [ "$want" != "$sg" ]; then echo "<html>denied</html>"; else echo '<html>{"access_token": "TESTTOKEN123"}</html>'; fi ;;
  versions|zigbee_devices)
    [ "$cfg" = 1 ] && grep -q 'Bearer TESTTOKEN123' && cat "$FAKE/body.$name" || echo '{"message":"401: Unauthorized"}' ;;
esac
STUB
chmod +x "$W/bin/"*

good() {
  rm -rf "$F"; mkdir -p "$F"
  echo 401 > "$F/code.versions"; echo 401 > "$F/code.zigbee_devices"; echo 404 > "$F/code.zz_no_such_route"
  echo "$GMV" > "$F/gm_version"
  printf '{"domain":"greenautarky_site","version":"2.13.1"}\n' > "$CC/greenautarky_site/manifest.json"
  echo BOSv1.6.1-rc2 > "$W/ga-release"
  printf '{"ga_release":"BOSv1.6.1-rc2","checks":[{"name":"versions.collect","details":{"addons":{"99f1cad4_ga_manager":{"name":"GA Manager","version":"%s"}}}}]}\n' "$GMV" > "$W/share/status.json"
  printf '{"status":"ok","bundle":"BOSv1.6.1-rc2","components":[{"group":"addon","id":"99f1cad4_ga_manager","name":"GA Manager","version":"%s"}]}\n' "$GMV" > "$F/body.versions"
  printf '{"devices":[{"name":"x","area":null}]}\n' > "$F/body.zigbee_devices"
  # a 48-byte base64url secret, as the console-login file holds
  head -c 48 /dev/urandom | base64 -w0 | tr '+/' '-_' | tr -d '=' > "$W/sec/console_login_secret"
  echo "$W/sec/console_login_secret" > "$F/secret_file"
}
run() { ds_run resident_info_device FAKE="$F" GA_RIN_BASE=http://ha.test GA_RIN_CC_DIR="$CC" GA_RIN_STATUS_FILE="$W/share/status.json" \
  GA_RIN_RELEASE_FILE="$W/ga-release" GA_RIN_SECRET_FILE="$W/sec/console_login_secret" "$@"; }

echo "== known-good, unauthenticated half"
good; run
for i in RIN-01 RIN-02 RIN-03 RIN-03c RIN-04; do ds_expect "$i" PASS "healthy device"; done
ds_expect RIN-10 SKIP "no GA_TEST_MINT_TOKEN"; ds_expect RIN-11 SKIP "no GA_TEST_MINT_TOKEN"
grep -q ga_remote_login "$F/curl.lines" && { echo "  FAIL  a credential was minted without the flag"; DS_FAIL=$((DS_FAIL + 1)); } || { echo "  ok    nothing minted without the flag"; DS_PASS=$((DS_PASS + 1)); }

echo "== known-good, authorized half"
good; run GA_TEST_MINT_TOKEN=1
ds_expect RIN-10 PASS "versions: ok, bundle, gm version"; ds_expect RIN-11 PASS "zigbee_devices array"
grep -q TESTTOKEN123 "$F/curl.lines" && { echo "  FAIL  the token appeared on a curl command line"; DS_FAIL=$((DS_FAIL + 1)); } || { echo "  ok    the token never appeared on a curl command line"; DS_PASS=$((DS_PASS + 1)); }

echo "== must-flag"
good; echo 404 > "$F/code.versions"; run;                                ds_expect RIN-02 FAIL "route missing (404)"
good; echo 200 > "$F/code.zigbee_devices"; run;                          ds_expect RIN-03 FAIL "answers anonymous users (200)"
good; echo 401 > "$F/code.zz_no_such_route"; run;                        ds_expect RIN-03c FAIL "everything is 401: the control catches it"
good; printf '{"version":"2.12.13"}\n' > "$CC/greenautarky_site/manifest.json"; run; ds_expect RIN-01 FAIL "site older than 2.13.0"
good; sed -i 's/BOSv1.6.1-rc2/BOSv1.6.0/' "$W/share/status.json"; run;   ds_expect RIN-04 FAIL "status.json release differs from /etc/ga-release"
good; echo 0.277.6 > "$F/gm_version"; run;                              ds_expect RIN-04 FAIL "status.json gm version differs from the container"
good; rm -f "$W/share/status.json"; run;                                 ds_expect RIN-04 FAIL "no status.json"
good; touch "$F/no_token"; run GA_TEST_MINT_TOKEN=1;                     ds_expect RIN-10 FAIL "no token could be minted"
good; head -c 48 /dev/urandom | base64 -w0 | tr '+/' '-_' | tr -d '=' > "$W/sec/other"; echo "$W/sec/other" > "$F/secret_file"; run GA_TEST_MINT_TOKEN=1
ds_expect RIN-10 FAIL "the server holds another secret: the signature is refused, no token"
good; sed -i 's/"status":"ok"/"status":"missing"/' "$F/body.versions"; run GA_TEST_MINT_TOKEN=1; ds_expect RIN-10 FAIL "/versions status missing"
good; sed -i 's/BOSv1.6.1-rc2/BOSv1.6.0/' "$F/body.versions"; run GA_TEST_MINT_TOKEN=1;        ds_expect RIN-10 FAIL "/versions bundle differs from /etc/ga-release"
good; printf '{"devices":"x"}\n' > "$F/body.zigbee_devices"; run GA_TEST_MINT_TOKEN=1;        ds_expect RIN-11 FAIL "devices is not an array"

ds_done
