#!/bin/sh
# time_share.sh — judge a bursty CPU consumer by the SHARE OF TIME it spends above a limit, over whole
# periods of its burst source, from a cumulative cgroup counter (not from point samples).
#
# Why: IDLE-10b took 12 `docker stats` points about 5 s apart and judged their p90. The Supervisor's
# load is one burst per ga_manager health tick (about 65 s, 4-8 s long). Twelve points span less than
# one period, so the verdict depended on where they landed: replayed over every start of a 45 min K31
# series (BOSv1.6.1-rc5, 2026-11-25), 12 % of the starts failed, on the same device in the same state.
#
# Same claim, measured properly. "p90 < 5 %" says: below 5 % for at least 90 % of the time. Here that
# is literally what is computed: the time with CPU > LIMIT, divided by the whole window, must stay below
# MAX_SHARE = 100 - 90. The limit is NOT relaxed: 5 % and 90 % are the old numbers.
# The window must cover at least MIN_WINDOW_S = 3 periods of 65 s, else the answer is "cannot judge".
#
#   ts_cpu_series <cpu.stat> <seconds>   prints "<epoch s> <usage_usec>" once per second
#   ts_verdict <limit%> <max share%> <min window s>   series on stdin; one summary line on stdout;
#                                        rc 0 pass, 1 over, 2 cannot judge (short, empty, counter reset)
TS_LIMIT=5
TS_MAX_SHARE=10
TS_MIN_WINDOW_S=195

ts_cpu_series() {
  _f="$1"; _n="$2"; _i=0
  while [ "$_i" -le "$_n" ]; do
    _u=$(sed -n 's/^usage_usec //p' "$_f" 2>/dev/null)
    [ -n "$_u" ] && echo "$(date +%s) $_u"
    _i=$((_i + 1)); [ "$_i" -le "$_n" ] && sleep 1
  done
}

ts_verdict() {
  awk -v lim="$1" -v maxs="$2" -v minw="$3" '
    NF != 2 { next }
    n > 0 {
      dt = $1 - t; du = $2 - u
      if (dt <= 0) { next }
      if (du < 0) { bad = "the counter went backwards (container restarted?)" }
      p = du / 1e6 / dt * 100; T += dt; cpu += du / 1e6
      if (p > lim) A += dt
      if (p > peak) peak = p
    }
    { t = $1; u = $2; n++ }
    END {
      if (bad != "") { print "cannot judge: " bad; exit 2 }
      if (T < minw) { printf "cannot judge: %d s measured, %d s needed (3 periods of the 65 s health tick)\n", T, minw; exit 2 }
      share = A / T * 100
      printf "%.1f %% of %d s above %g %% (allowed < %g %%), mean %.2f %%, peak %.1f %%\n", share, T, lim, maxs, cpu / T * 100, peak
      exit (share < maxs ? 0 : 1)
    }'
}
