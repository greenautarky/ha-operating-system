#!/bin/sh
# Host-side selftest of the OTA seam checks in ota_update/test.sh (OTA-12..16, OTA-18):
# the LIVE suite against a curl stub that answers per URL, and OTA-18 against the LIVE
# shipped ga-rauc-install plus one-defect mutants of it. Known-good PASS, each defect FAIL,
# and the "not promoted" SKIP on an affirmative 404 only (any label: KB #381 promotes a final after its gate).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/devsuite_selftest.sh"
ds_init
HELPER="$DS_ROOT/../buildroot-external/rootfs-overlay/usr/sbin/ga-rauc-install"
[ -s "$HELPER" ] || { echo "FATAL: $HELPER missing"; exit 2; }
F="$W/f"; mkdir -p "$F"
cat > "$W/bin/curl" <<'STUB'
#!/bin/sh
# answers by URL suffix from $FAKE/codes ("<suffix> <code>"); -w '%{http_code}' prints the code,
# -f turns a non-200 into exit 22, 000 is a connect failure (exit 7)
for a; do url=$a; done
w=; f=; for a; do case "$a" in -w) w=1 ;; -*f*) f=1 ;; esac; done
code=$(awk -v u="$url" 'index(u, $1) == length(u) - length($1) + 1 {c=$2} END {print c}' "$FAKE/codes")
[ -n "$code" ] || code=404
[ -n "$w" ] && printf '%s' "$code"
[ "$code" = 000 ] && exit 7
if [ "$code" = 200 ] && [ -z "$w" ]; then
  case "$url" in *PROMOTED.json) echo '{"ga_release":"BOSv1.6.1"}' ;; *.sha256) printf '%064d  haos_ihost-1\n' 0 ;; esac
fi
[ -n "$f" ] && [ "$code" != 200 ] && exit 22
exit 0
STUB
chmod +x "$W/bin/curl"
echo pinned-endpoint > "$W/pin"
codes() {   # codes <promoted> <prod bundle> <sha> <rc slot>
  printf 'PROMOTED.json %s\nhaos_ihost-18.4.1.6.raucb %s\nhaos_ihost-18.4.1.6.raucb.sha256 %s\nBOSv1.6.1-rc9/haos_ihost-18.4.1.6.raucb %s\nBOSv1.6.1/haos_ihost-18.4.1.6.raucb %s\n' "$1" "$2" "$3" "$4" "$4" > "$F/codes"
}
# NB the stub matches by suffix: the slot URLs end in the same file name as the prod bundle,
# so the per-label slot lines come first and the prod-bundle line is anchored by "/releases/18.4.1.6/".
run() {   # run <label> [VAR=val ...]
  _l="$1"; shift
  echo "$_l" > "$W/rel"
  ds_run ota_update FAKE="$F" GA_OTA_VERSION_ID=18.4.1.6 GA_OTA_RELEASE_FILE="$W/rel" GA_OTA_PIN_FILE="$W/pin" "$@"
}
codes() {
  printf 'PROMOTED.json %s\n/18.4.1.6/haos_ihost-18.4.1.6.raucb %s\nraucb.sha256 %s\n/BOSv1.6.1-rc9/haos_ihost-18.4.1.6.raucb %s\n/BOSv1.6.1/haos_ihost-18.4.1.6.raucb %s\n' "$1" "$2" "$3" "$4" "$4" > "$F/codes"
}

echo "== known-good: promoted final release"
codes 200 200 200 200; run BOSv1.6.1
for i in 12 13 14 15 16; do ds_expect "OTA-$i" PASS "promoted, everything served"; done
echo "== not promoted: pre-release build, server answers 404"
codes 404 404 404 200; run BOSv1.6.1-rc9
ds_expect OTA-12 PASS "host answered 404 = not promoted"
for i in 13 14 15; do ds_expect "OTA-$i" SKIP "pre-release + PROMOTED.json 404: explicit skip"; done
ds_expect OTA-16 PASS "rc slot staged"
codes 404 404 404 404; run BOSv1.6.1-rc9
ds_expect OTA-16 FAIL "rc slot not staged / pruned stays red"
echo "== the skip must not hide a failure"
echo "== not promoted yet: FINAL label, server answers 404 (gate runs before promotion, KB #381)"
codes 404 404 404 200; run BOSv1.6.1
ds_expect OTA-12 PASS "FINAL label, host answered 404 = not promoted yet"
for i in 13 14 15; do ds_expect "OTA-$i" SKIP "FINAL + PROMOTED.json 404: explicit skip, never a pass"; done
codes 000 000 000 200; run BOSv1.6.1
ds_expect OTA-12 FAIL "FINAL label, host does not answer: no skip"
ds_expect OTA-13 FAIL "FINAL label, no answer: no skip"
codes 403 403 403 200; run BOSv1.6.1
ds_expect OTA-14 FAIL "FINAL label, 403 is not 'not promoted'"
codes 200 404 200 200; run BOSv1.6.1
ds_expect OTA-14 FAIL "promoted FINAL, prod bundle 404 = a real failure"
codes 000 000 000 000; run BOSv1.6.1-rc9
ds_expect OTA-12 FAIL "pre-release, host does not answer (connect failure)"
ds_expect OTA-13 FAIL "pre-release, no answer: no skip"
codes 403 403 403 200; run BOSv1.6.1-rc9
ds_expect OTA-12 FAIL "pre-release, 403 is not 'not promoted'"
ds_expect OTA-14 FAIL "pre-release, 403: no skip"
codes 200 404 200 200; run BOSv1.6.1-rc9
ds_expect OTA-12 PASS "pre-release but PROMOTED: strict, host answers 200"
ds_expect OTA-14 FAIL "promoted rc build, prod bundle 404 = a real failure"
codes 200 200 404 200; run BOSv1.6.1-rc9
ds_expect OTA-15 FAIL "promoted rc build, checksum 404"
codes 404 404 404 200; run ""
ds_expect OTA-12 FAIL "empty label fails closed"

echo "== OTA-18 against the LIVE ga-rauc-install and one-defect mutants"
h18() { ds_run ota_update FAKE="$F" GA_RAUC_HELPER="$1"; }
M="$W/m"; mkdir -p "$M"
mut() { sed "$2" "$HELPER" > "$M/$1"; cmp -s "$HELPER" "$M/$1" && { echo "  FATAL mutant $1 identical to the live helper (pattern stale)"; DS_FAIL=$((DS_FAIL+1)); }; }
codes 404 404 404 404
h18 "$HELPER";                                                   ds_expect OTA-18 PASS "live helper: every call site pins the endpoint"
# the shape shipped on release/1.6.1 (curl pinned inline at two call sites), kept as a fixture so
# both shapes stay covered whichever one the live helper has on this branch
INLINE="$SCRIPT_DIR/fixtures/ga-rauc-install.inline-resolve"
h18 "$INLINE";                                                   ds_expect OTA-18 PASS "inline-resolve shape (release/1.6.1): pinned"
mut no-resolve-any 's/--resolve "\$OTA_RESOLVE" //g'
h18 "$M/no-resolve-any";                                         ds_expect OTA-18 FAIL "live helper: pin removed everywhere"
sed 's/--resolve "\$OTA_RESOLVE" //' "$INLINE" > "$M/inline-nopin-all"
h18 "$M/inline-nopin-all";                                       ds_expect OTA-18 FAIL "inline shape: first call site loses the pin (sed hits the first of each line)"
sed '0,/--resolve "\$OTA_RESOLVE" /s///' "$INLINE" > "$M/inline-nopin-first"
h18 "$M/inline-nopin-first";                                     ds_expect OTA-18 FAIL "inline shape: only the first ota_curl loses the pin"
sed 's/--resolve "\$OTA_RESOLVE" --output/--output/' "$INLINE" > "$M/inline-nopin-fallback"
h18 "$M/inline-nopin-fallback";                                  ds_expect OTA-18 FAIL "inline shape: only the fallback ota_curl loses the pin"
{ cat "$HELPER"; printf '\ncurl -fsS "https://${OTA_HOST}/x" -o /dev/null\n'; } > "$M/bare-curl"
h18 "$M/bare-curl";                                              ds_expect OTA-18 FAIL "bare curl at a call site outside the wrapper"
{ cat "$HELPER"; printf '\nif ! curl --fail "$U"; then :; fi\n'; } > "$M/bare-curl-if"
h18 "$M/bare-curl-if";                                           ds_expect OTA-18 FAIL "bare curl after if !"
mut wrapper-drops-args 's/curl "\$@"/curl/'
h18 "$M/wrapper-drops-args";                                     ds_expect OTA-18 FAIL "the wrapper drops \"\$@\" (no pin reaches curl)"
mut no-call-sites 's/\(^\|[ (]\)ota_curl \([-"]\)/\1echo \2/g'
h18 "$M/no-call-sites";                                          ds_expect OTA-18 FAIL "no download call site found: zero inspected fails"
if grep -q '^ *set -- .*--resolve' "$HELPER"; then   # the resumable-fetch shape: arguments assembled with set --
  mut set-list-without-pin '/^ *set -- .*--resolve/s/--resolve "\$OTA_RESOLVE" //'
  h18 "$M/set-list-without-pin";                                 ds_expect OTA-18 FAIL "the set -- argument list loses the pin, ota_curl \"\$@\" forwards it"
fi
mut no-pin-file 's|/run/ga-resolve-ota.active|/run/x|g'
h18 "$M/no-pin-file";                                            ds_expect OTA-18 FAIL "helper does not read the resolver's pin file"
ds_done
