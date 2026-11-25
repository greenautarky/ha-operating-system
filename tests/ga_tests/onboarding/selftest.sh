#!/bin/sh
# Host-side selftest of PW-02, PW-03 and OB-WR-03 in onboarding/test.sh: the LIVE suite against
# a curl stub. Since #1895 the password-reset API answers exactly 403 password_reset_disabled;
# since 2.12.13 (#1917) the wizard redirect keeps ?device= and drops ?pin=. Known-good must
# PASS, every other state must FAIL (never "any 4xx").
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/devsuite_selftest.sh"
ds_init
F="$W/f"; mkdir -p "$F"
echo '{"data":{"completed":false}}' > "$W/site.json"
cat > "$W/bin/curl" <<'STUB'
#!/bin/sh
# POST (password reset): body + status from $FAKE/pw_code, $FAKE/pw_body; root probe: $FAKE/redirect
post=; red=; for a; do [ "$a" = POST ] && post=1; case "$a" in *redirect_url*) red=1 ;; esac; done
if [ -n "$post" ]; then printf '%s\n%s\n' "$(cat "$FAKE/pw_body")" "$(cat "$FAKE/pw_code")"; exit 0; fi
[ -n "$red" ] && { cat "$FAKE/redirect"; exit 0; }
exit 22
STUB
chmod +x "$W/bin/curl"
DIS='{"error": "Password reset is currently unavailable", "code": "password_reset_disabled", "message": "x"}'
run() { ds_run onboarding FAKE="$F" GA_HA_PORT=80 GA_OB_SITE_STORE="$W/site.json"; }
good() { printf '%s' "$DIS" > "$F/pw_body"; echo 403 > "$F/pw_code"; echo "302 http://127.0.0.1/greenautarky-setup.html?device=ob-wr-probe" > "$F/redirect"; }

echo "== known-good: reset disabled, PIN dropped, device kept"
good; run
ds_expect PW-02 PASS "403 password_reset_disabled"
ds_expect PW-03 PASS "403 password_reset_disabled"
ds_expect OB-WR-03 PASS "redirect without pin, with device"
echo "== must-fail: password reset"
good; echo 200 > "$F/pw_code"; echo '{"result":"ok"}' > "$F/pw_body"; run
ds_expect PW-02 FAIL "a reset that succeeds (200)"; ds_expect PW-03 FAIL "a reset that succeeds (200)"
good; echo 401 > "$F/pw_code"; echo '{"error":"bad pin"}' > "$F/pw_body"; run
ds_expect PW-02 FAIL "401: the old behaviour is not the expected state"
good; echo 429 > "$F/pw_code"; run
ds_expect PW-02 FAIL "429 with the disabled body: not exactly 403"
good; echo 404 > "$F/pw_code"; echo 'Not Found' > "$F/pw_body"; run
ds_expect PW-03 FAIL "404: view not registered"
good; echo '{"error":"wizard complete","code":"wizard_complete"}' > "$F/pw_body"; run
ds_expect PW-02 FAIL "403 with another code is not password_reset_disabled"
good; echo 403 > "$F/pw_code"; echo '<html>forbidden</html>' > "$F/pw_body"; run
ds_expect PW-03 FAIL "403 without the code"
echo "== must-fail: wizard redirect"
good; echo "302 http://127.0.0.1/greenautarky-setup.html?pin=000000&device=ob-wr-probe" > "$F/redirect"; run
ds_expect OB-WR-03 FAIL "the PIN is forwarded in the Location"
good; echo "302 http://127.0.0.1/greenautarky-setup.html?device=ob-wr-probe&pin=000000" > "$F/redirect"; run
ds_expect OB-WR-03 FAIL "the PIN is forwarded after device="
good; echo "302 http://127.0.0.1/greenautarky-setup.html" > "$F/redirect"; run
ds_expect OB-WR-03 FAIL "device= dropped too (kept on purpose)"
good; echo "302 http://127.0.0.1/greenautarky-setup.html?device=ob-wr-probe&x=000000" > "$F/redirect"; run
ds_expect OB-WR-03 FAIL "the PIN value travels under another name"
good; echo "200 " > "$F/redirect"; run
ds_expect OB-WR-03 FAIL "no redirect at all while the wizard is incomplete"
ds_done
