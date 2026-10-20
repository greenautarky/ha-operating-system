#!/bin/sh
# Self-test for lib/boot_settle.sh and its use by TEL-10 / NET-03 / NET-03b / NET-04
# (Odoo #1222). Host-side, no device. Run from repo root:
#   sh tests/ga_tests/lib/boot_settle_selftest.sh
# Drives the LIVE helper functions through their seams, and reads the LIVE suite
# files (no re-declared copy). Both directions:
#   must RUN   a settled device (uptime >= threshold); a young device that
#              becomes settled while we wait
#   must SKIP  a young device whose wait bound is hit; an unreadable uptime
#   suites     the four tests go through settled_run_test and still carry the
#              pinned 5-min assertions (nothing weakened)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

. "$HERE/test_helpers.sh"
. "$HERE/boot_settle.sh"
export GA_SETTLE_SECS=660 GA_SETTLE_INTERVAL=10

# fake run_test / skip_test record what happened
RAN=""; SKIPPED=""; SKIP_WHY=""
run_test()  { RAN="$RAN $1"; }
skip_test() { SKIPPED="$SKIPPED $1"; SKIP_WHY="$3"; }
reset() { RAN=""; SKIPPED=""; SKIP_WHY=""; }

# 1. settled device -> runs, no wait
reset; GA_UPTIME_CMD='echo 3000' GA_SETTLE_WAIT=0 settled_run_test X1 d true
[ "$RAN" = " X1" ] && [ -z "$SKIPPED" ] && ok "settled device runs the test" || bad "settled device: ran='$RAN' skipped='$SKIPPED'"

# 2. young device, bound 0 -> SKIP with a reason that names uptime and the threshold
reset; GA_UPTIME_CMD='echo 120' GA_SETTLE_WAIT=0 settled_run_test X2 d true
case "$SKIP_WHY" in *"120"*"660"*) _w=1 ;; *) _w=0 ;; esac
[ -z "$RAN" ] && [ "$SKIPPED" = " X2" ] && [ "$_w" = 1 ] && ok "young device skips with stated reason" || bad "young device: ran='$RAN' skipped='$SKIPPED' why='$SKIP_WHY'"

# 3. young device that settles while we wait -> runs (uptime advances 10 s per fake sleep)
UPF=$(mktemp); echo 600 > "$UPF"
reset
GA_UPTIME_CMD="cat $UPF" GA_SETTLE_SLEEP_CMD="sh -c 'echo \$((\$(cat $UPF) + 30)) > $UPF' #" GA_SETTLE_WAIT=300 settled_run_test X3 d true
[ "$RAN" = " X3" ] && [ -z "$SKIPPED" ] && ok "young device that settles during the wait runs" || bad "settling device: ran='$RAN' skipped='$SKIPPED' up=$(cat "$UPF")"
rm -f "$UPF"

# 4. unreadable uptime -> fail closed (skip, never run)
reset; GA_UPTIME_CMD='echo' GA_SETTLE_WAIT=0 settled_run_test X4 d true
[ -z "$RAN" ] && [ "$SKIPPED" = " X4" ] && ok "unreadable uptime skips (fail closed)" || bad "unreadable uptime: ran='$RAN' skipped='$SKIPPED'"

# 5. live suites: the four ids go through settled_run_test ...
for pair in "telemetry/test.sh:TEL-10" "network/test.sh:NET-03" "network/test.sh:NET-03b" "network/test.sh:NET-04"; do
  f="$HERE/../${pair%%:*}"; id="${pair##*:}"
  if grep -q "^settled_run_test \"$id\" " "$f"; then ok "$id uses settled_run_test"; else bad "$id does not use settled_run_test ($f)"; fi
done
# ... and still assert the pinned 5-min window and the same error patterns
grep -A1 '^settled_run_test "TEL-10"' "$HERE/../telemetry/test.sh" | grep -q "since '5 min ago'.*error.\*output.*connection refused" \
  && ok "TEL-10 assertion unchanged" || bad "TEL-10 assertion changed"
grep -A1 '^settled_run_test "NET-03"' "$HERE/../network/test.sh" | grep -q "since '5 min ago'.*no upstream connections.*connection refused" \
  && ok "NET-03 assertion unchanged" || bad "NET-03 assertion changed"
grep -A1 '^settled_run_test "NET-03b"' "$HERE/../network/test.sh" | grep -q "since '5 min ago'.*no upstream|broken connection|HTTP status=\[45\]" \
  && ok "NET-03b assertion unchanged" || bad "NET-03b assertion changed"
grep -A1 '^settled_run_test "NET-04"' "$HERE/../network/test.sh" | grep -q "since '5 min ago'.*failed to flush.*connection refused" \
  && ok "NET-04 assertion unchanged" || bad "NET-04 assertion changed"

echo "boot_settle selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && [ "$pass" -ge 11 ]
