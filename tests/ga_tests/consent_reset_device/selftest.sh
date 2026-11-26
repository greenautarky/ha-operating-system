#!/bin/sh
# Host-side selftest of consent_reset_device (TEL-54): the LIVE suite against stubs of curl, docker
# (the websocket helper), openssl and a fake device tree. Known-good must PASS; the old behaviour
# (reset records tier 1) and every broken state must FAIL the named check; without the flag: SKIP.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/devsuite_selftest.sh"
ds_init
F="$W/f"; D="$W/dev"; mkdir -p "$F" "$D/m"
cat > "$W/bin/curl" <<'STUB'
#!/bin/sh
for a; do case "$a" in
  *ga_remote_login*) cat "$FAKE/login"; exit 0 ;;
  */api/greenautarky_site/reset) cat > /dev/null; mode=$(cat "$FAKE/mode")
    case "$mode" in
      good) rm -f "$DEV/store"; [ "$(cat "$FAKE/unit")" = ok ] && rm -f "$DEV"/m/.ga-consent-* ;;
      old)  echo '{"data":{"tiers":{"tier1":{"value":true}}}}' > "$DEV/store"; rm -f "$DEV"/m/.ga-consent-tier2 "$DEV"/m/.ga-consent-metrics; : > "$DEV/m/.ga-consent-tier1" ;;
    esac
    printf '%s\n%s\n' "$(cat "$FAKE/reset_body")" "$(cat "$FAKE/reset_code")"; exit 0 ;;
esac; done
exit 22
STUB
cat > "$W/bin/docker" <<'STUB'
#!/bin/sh
[ "$1" = exec ] || exit 0   # test_helpers calls `docker inspect` at load time: never read stdin then
in=$(cat); cmd=$(printf '%s' "$in" | tail -n 1)
case "$cmd" in
  *telemetry/set*) [ "$(cat "$FAKE/set")" = ok ] && { echo '{"data":{"tiers":{"tier2":{"value":true}}}}' > "$DEV/store"; : > "$DEV/m/.ga-consent-tier2"; rm -f "$DEV/m/.ga-consent-tier1"; }; echo '{}' ;;
  *telemetry/get*) [ -e "$DEV/store" ] && echo '{"policy_version_accepted":1}' || echo '{"policy_version_accepted":null}' ;;
esac
STUB
printf '#!/bin/sh\ncat >/dev/null; printf "sig"\n' > "$W/bin/openssl"
chmod +x "$W/bin/"*
printf 'c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0' > "$F/secret"
good() { echo good > "$F/mode"; echo ok > "$F/set"; echo ok > "$F/unit"; echo 200 > "$F/reset_code"; echo '{"status":"ok","telemetry_reset":"cleared"}' > "$F/reset_body"
  printf '<script>{"access_token": "tok-123", "x": 1}</script>' > "$F/login"; rm -rf "$D"; mkdir -p "$D/m"; : > "$D/m/.ga-consent-tier1"; }
run() { ds_run consent_reset_device FAKE="$F" DEV="$D" GA_TEST_DESTRUCTIVE="${1:-1}" GA_TEL54_BASE=http://127.0.0.1:80 \
  GA_TEL54_STORE="$D/store" GA_TEL54_MARKER_DIR="$D/m" GA_TEL54_SECRET_FILE="$F/secret" GA_TEL54_WAIT=2; }
ALL="TEL-54a TEL-54b TEL-54c TEL-54d TEL-54e"

echo "== known-good (site >= 2.16.0 + telemetry >= 0.2.5)"
good; run; for i in $ALL; do ds_expect "$i" PASS "reset forgets the decision"; done
echo "== the old behaviour: the reset records the starting values"
good; echo old > "$F/mode"; echo '{"status":"ok","telemetry_reset":"reset"}' > "$F/reset_body"; run
ds_expect TEL-54a PASS "the decision itself still arrives"
for i in TEL-54b TEL-54c TEL-54d TEL-54e; do ds_expect "$i" FAIL "a record and the tier-1 marker are back"; done
echo "== must-fail, one property each"
good; echo nothing > "$F/unit"; run; ds_expect TEL-54e FAIL "markers stay although the record is gone"; ds_expect TEL-54c PASS "record gone"
good; echo 500 > "$F/reset_code"; echo '{"code":"telemetry_component_outdated"}' > "$F/reset_body"; echo none > "$F/mode"; run
ds_expect TEL-54b FAIL "refused reset"; ds_expect TEL-54c FAIL "record still there"
good; echo broken > "$F/set"; run; ds_expect TEL-54a FAIL "the decision never reached the device"
good; printf '<html>no token</html>' > "$F/login"; run; for i in $ALL; do ds_expect "$i" FAIL "no token: nothing proven, never a pass"; done
echo "== not destructive: everything skipped, nothing touched"
good; run 0; for i in $ALL; do ds_expect "$i" SKIP "flag not set"; done
[ -e "$D/m/.ga-consent-tier1" ] && { DS_PASS=$((DS_PASS + 1)); echo "  ok    nothing touched without the flag"; } || { DS_FAIL=$((DS_FAIL + 1)); echo "  FAIL  touched without the flag"; }
ds_done
