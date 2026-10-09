#!/bin/sh
# sample_window.sh — judge a fluctuating metric over a WINDOW, not one sample.
#
# Why: a single reading lands on a periodic burst often enough to fail a
# healthy device. IDLE-05 (I/O wait) and IDLE-10b (Supervisor container CPU)
# each judged ONE sample, and IDLE-10b failed idle devices while every other
# idle check passed: the Supervisor answers ga_manager's health
# tick, which shows up as one short burst about every 65 s. A burst that
# covers one sample of twelve is not an idle problem; a value that stays high
# across the window is.
#
# Usage (sourced):
#   . lib/sample_window.sh
#   values=$(sample_window <count> <interval_s> <command…>)   # one number per line
#   p=$(window_p90 "$values")                                   # integer, nearest rank
#   echo "$values" | window_summary                             # "n=12 min=0 p90=1 max=35"
#
# The sampler is any command that prints one number (decimals allowed; the
# first number on its output is taken). A sample that prints nothing is
# recorded as nothing, and window_p90 refuses a window with no samples
# (prints "", the caller must fail on that) — zero samples is not a pass.
#
# p90 = nearest rank: the ceil(0.9 * n)-th smallest value. With n = 12 that
# is the 11th, so exactly one high sample in the window is tolerated and two
# are not. Self-test: lib/sample_window_selftest.sh (runs in CI).

# sample_window <count> <interval_s> <cmd...> — run cmd <count> times, <interval_s> apart.
sample_window() {
  _sw_n="$1"; _sw_int="$2"; shift 2
  _sw_i=0
  while [ "$_sw_i" -lt "$_sw_n" ]; do
    [ "$_sw_i" -gt 0 ] && [ "$_sw_int" != 0 ] && sleep "$_sw_int"
    "$@" 2>/dev/null | awk 'match($0, /-?[0-9]+(\.[0-9]+)?/) { print substr($0, RSTART, RLENGTH); exit }'
    _sw_i=$((_sw_i + 1))
  done
}

# window_p90 "<values, one per line>" — integer p90 (nearest rank), "" if no samples.
window_p90() {
  printf '%s\n' "$1" | awk 'NF { print $1 + 0 }' | sort -n | awk '
    { v[NR] = $1 }
    END {
      if (NR == 0) exit
      r = int(0.9 * NR); if (r < 0.9 * NR) r++
      printf "%d\n", v[r]
    }'
}

# window_summary — "n=<count> min=<..> p90=<..> max=<..>" from values on stdin.
window_summary() {
  awk 'NF { print $1 + 0 }' | sort -n | awk '
    { v[NR] = $1 }
    END {
      if (NR == 0) { print "n=0"; exit }
      r = int(0.9 * NR); if (r < 0.9 * NR) r++
      printf "n=%d min=%g p90=%d max=%g\n", NR, v[1], v[r], v[NR]
    }'
}
