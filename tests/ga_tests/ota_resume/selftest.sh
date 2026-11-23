#!/bin/sh
# ota_resume/selftest.sh — each guard of the ota_resume suite goes red on the
# defect it exists for (working-method rules 50/51).
#
# Mutants are made from the LIVE installer by exact text replacement; a target
# that is no longer in the script is a FAILURE, never a skip (the self-test must
# not rot into a copy). For every mutant the suite runs in full and the named
# check(s) must FAIL - a different check catching it does not count. The live
# installer must pass every check (known-good baseline first: a mutation into a
# red suite proves nothing).
set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SUITE="$ROOT/tests/ga_tests/ota_resume/test.sh"
LIVE="$ROOT/buildroot-external/rootfs-overlay/usr/sbin/ga-rauc-install"
W="$(mktemp -d -t ota-resume-self-XXXXXX)"
trap 'rm -rf "$W"' EXIT

pass=0; fail=0
PASS() { echo "  PASS  $1"; pass=$((pass+1)); }
FAIL() { echo "  FAIL  $1${2:+ ($2)}"; fail=$((fail+1)); }

# All runs are independent (own work dir, own network+PID namespace) and mostly
# wait, so they run IN PARALLEL: serially they took ~33 min (a 65 s backoff case
# per run) and hit the CI step timeout. The known-good baseline is still
# evaluated FIRST - a mutant result means nothing against a red baseline.
: > "$W/jobs"
( sh "$SUITE" > "$W/live.out" 2>&1; echo $? > "$W/live.rc" ) &

mutant() {  # <name> <old> <new>
  python3 -I - "$LIVE" "$W/$1" "$2" "$3" <<'PYEOF'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if s.count(old) != 1:
    print(f"mutation target found {s.count(old)}x (want 1): {old!r}")
    sys.exit(1)
open(dst, "w").write(s.replace(old, new, 1))
PYEOF
}
expect() {  # <id> <mutant> <desc> <check-id>...
  _id="$1"; _m="$2"; _d="$3"; shift 3
  if ! mutant "$_m" "$MOLD" "$MNEW" > "$W/$_m.mut" 2>&1; then
    FAIL "$_id $_d" "$(cat "$W/$_m.mut")"; return
  fi
  ( GA_OTAR_INSTALLER="$W/$_m" sh "$SUITE" > "$W/$_m.out" 2>&1 ) &
  printf '%s|%s|%s|%s\n' "$_id" "$_m" "$_d" "$*" >> "$W/jobs"
}
evaluate() {
  wait
  if [ "$(cat "$W/live.rc" 2>/dev/null)" = 0 ] && grep -q ' 0 failed' "$W/live.out" && ! grep -q '^  FAIL' "$W/live.out"; then
    PASS "SELF-00 the live installer passes the whole suite"
  else
    FAIL "SELF-00 the live installer passes the whole suite" "$(grep '^  FAIL' "$W/live.out" | head -3 | tr '\n' ';')"
    echo "--- ota_resume selftest: baseline red, mutant results not counted ---"; exit 1
  fi
  while IFS='|' read -r _id _m _d _checks; do
    _miss=""
    for _c in $_checks; do grep -q "^  FAIL  $_c " "$W/$_m.out" || _miss="$_miss $_c"; done
    if [ -z "$_miss" ]; then PASS "$_id $_d: red on $_checks"
    else FAIL "$_id $_d" "not red:$_miss; red were: $(grep '^  FAIL' "$W/$_m.out" | cut -c9-20 | tr '\n' ' ')"; fi
  done < "$W/jobs"
}

MOLD='        if [ "$_rc" != 22 ] || [ "$_code" != 404 ]; then'
MNEW='        if false; then'
expect SELF-01 m-fallback-any "falling back to the prod slot on ANY sidecar error" OTAR-05 OTAR-05c

MOLD='        set -- "$@" --continue-at -'
MNEW='        :'
expect SELF-02 m-no-resume "no HTTP Range resume" OTAR-02b OTAR-02c

MOLD='    if [ "$_have" != "$_want" ]; then'
MNEW='    if false; then'
expect SELF-03 m-no-verify "the sha256 check skipped" OTAR-06

MOLD='       && mv -f "$STATE_REQ.tmp" "$STATE_REQ"
}'
MNEW='       && rm -f "$STATE_REQ.tmp"
}'
expect SELF-04 m-no-persist "the accepted request not persisted" OTAR-08

MOLD='"next_retry_at":%s,'
MNEW='"retry_at":%s,'
expect SELF-05 m-status-key "a status key renamed (the seam to ga_manager)" OTAR-12

MOLD='--speed-limit "$LOW_SPEED" --speed-time "$STALL_S"'
MNEW='--speed-limit 1 --speed-time 99999'
expect SELF-06 m-no-stall "no stall detection" OTAR-03

MOLD='    gm_request_pending || return 0'
MNEW='    return 0'
expect SELF-07 m-no-supersede "a new request does not supersede" OTAR-09

MOLD='            rm -f "$PART" "$PART_ETAG"
            FETCH_ERR="the server did not resume - starting from 0"'
MNEW='            FETCH_ERR="the server did not resume - starting from 0"'
expect SELF-08 m-keep-on-33 "a refused resume keeps the stale partial" OTAR-15

MOLD='    if [ $(( $(uptime_s) - _run_start )) -ge "$DEADLINE_S" ]; then'
MNEW='    if false; then'
expect SELF-09 m-no-deadline "no per-run deadline" OTAR-16

MOLD='ATTEMPT="$ATTEMPTS_USED"'
MNEW='ATTEMPT=0'
expect SELF-10 m-attempts-reset "the attempt count restarts on every run (endless retries across reboots)" OTAR-17

MOLD='            write_status retrying "$(fsize "$PART")" "" "$FETCH_ERR" $((_now + _pause))
            _beat=0'
MNEW='            _beat=0'
expect SELF-11 m-no-heartbeat "no status heartbeat during a backoff pause" OTAR-18

MOLD='( while :; do sleep "$HEARTBEAT_S"; write_status installing "$_isize" "$_isize"; done ) &'
MNEW='( : ) &'
expect SELF-12 m-no-install-heartbeat "no status heartbeat during rauc install" OTAR-19

evaluate
echo "--- ota_resume selftest: $pass passed, $fail failed ---"
[ "$fail" = 0 ]
