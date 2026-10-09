#!/bin/sh
# Self-test for lib/sample_window.sh and its use by idle_perf IDLE-05 / IDLE-10b.
# Host-side, no device. Run from repo root:
#   sh tests/ga_tests/lib/sample_window_selftest.sh
#
# Fixture: fixtures/idle_sup_cpu_burst_trace.txt — Supervisor CPU every 5 s with
# one ~35 % burst per ~65 s (the ga_manager health tick). Both directions:
#   must PASS  every 12-sample window of that trace (the false positive is gone)
#   must FAIL  a Supervisor that stays busy, two bursts in one window, no samples
# and the OLD single-sample rule is shown failing on the burst sample (red).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/sample_window.sh"
TRACE="$HERE/fixtures/idle_sup_cpu_burst_trace.txt"
SUITE="$HERE/../idle_perf/test.sh"
LIMIT=5
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

values=$(grep -v '^#' "$TRACE")
total=$(printf '%s\n' "$values" | grep -c .)
[ "$total" -ge 26 ] || { echo "FAIL: trace has $total samples, need >= 26"; exit 1; }

# 1. every 12-sample window of the burst trace passes on p90
n_windows=0; n_fail=0
i=1
while [ $((i + 11)) -le "$total" ]; do
  w=$(printf '%s\n' "$values" | sed -n "${i},$((i + 11))p")
  p=$(window_p90 "$w")
  n_windows=$((n_windows + 1))
  if [ -z "$p" ] || [ "$p" -ge "$LIMIT" ]; then
    n_fail=$((n_fail + 1)); echo "        window @$i: $(printf '%s\n' "$w" | window_summary)"
  fi
  i=$((i + 1))
done
[ "$n_windows" -gt 0 ] && [ "$n_fail" -eq 0 ] \
  && ok "burst trace: all $n_windows sliding 12-sample windows have p90 < $LIMIT" \
  || bad "burst trace: $n_fail of $n_windows windows judged busy"

# 2. the old rule (one sample) on the burst sample fails — the false positive
burst=$(printf '%s\n' "$values" | sort -n | tail -1)
burst_i=$(printf '%d' "$burst" 2>/dev/null || echo "${burst%%.*}")
[ "$burst_i" -ge "$LIMIT" ] \
  && ok "old single-sample rule fails on the burst sample (${burst}%) — the bug" \
  || bad "trace has no burst sample >= $LIMIT; it cannot show the bug"

# 3. a Supervisor that stays busy still fails
busy=$(printf '%s\n' 8 12 9.5 15 7 20 11 6 9 13 10 8)
p=$(window_p90 "$busy")
[ -n "$p" ] && [ "$p" -ge "$LIMIT" ] && ok "sustained 6-20 % fails (p90=$p)" || bad "sustained load passed (p90=$p)"

# 4. two bursts in one window are not tolerated
two=$(printf '%s\n' 0.5 35 0.4 0.6 0.3 0.5 31 0.2 0.4 0.5 0.3 0.6)
p=$(window_p90 "$two")
[ -n "$p" ] && [ "$p" -ge "$LIMIT" ] && ok "two bursts in 12 samples fail (p90=$p)" || bad "two bursts passed (p90=$p)"

# 5. zero samples is not a pass
p=$(window_p90 "")
[ -z "$p" ] && ok "no samples -> empty p90 (the caller fails)" || bad "no samples gave p90=$p"

# 6. sample_window: takes the first number of each sample, drops empty ones
pct() { echo "hassio_supervisor 35.20%"; }
none() { :; }
got=$(sample_window 3 0 pct | tr '\n' ' ')
[ "$got" = "35.20 35.20 35.20 " ] && ok "sample_window parses docker-style '35.20%'" || bad "sample_window gave '$got'"
got=$(sample_window 3 0 none | grep -c .)
[ "$got" -eq 0 ] && ok "a sampler that prints nothing yields no sample" || bad "empty sampler yielded $got samples"

# 7. the suite really judges IDLE-05 and IDLE-10b on the window
for id in IDLE-05 IDLE-10b; do
  blk=$(grep -B3 -A1 "run_test_show \"$id\"" "$SUITE")
  echo "$blk" | grep -q 'window_p90' && echo "$blk" | grep -q '\-n \\"\$' \
    && ok "$id in idle_perf/test.sh is judged on window_p90 and fails on no samples" \
    || bad "$id in idle_perf/test.sh is not judged on window_p90"
done
grep -q '^\. "\$SCRIPT_DIR/\.\./lib/sample_window\.sh"' "$SUITE" \
  && ok "idle_perf/test.sh sources lib/sample_window.sh" || bad "idle_perf/test.sh does not source the lib"

echo "sample_window: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && [ "$pass" -ge 10 ]
