#!/bin/sh
# Self-test for lib/time_share.sh and IDLE-10b. Host-side.
#   must PASS  the real 45 min K31 rc5 series, whole and EVERY 195 s window of it
#   must FAIL  the October series (gm 0.252: stats sweep every tick, 19 % of the time above 5 %),
#              a synthetic constant 6 %
#   cannot judge (rc 2)  shorter than 3 periods, empty, counter reset
#   red proof  the old rule (p90 of 12 points 5 s apart) on the SAME rc5 series fails for some starts
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/time_share.sh"; . "$HERE/sample_window.sh"
FX="$HERE/fixtures"; SUITE="$HERE/../idle_perf/test.sh"; W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
v() { grep -v '^#' "$1" | ts_verdict "$TS_LIMIT" "$TS_MAX_SHARE" "$TS_MIN_WINDOW_S"; }
[ "$TS_LIMIT" = 5 ] && [ "$TS_MAX_SHARE" = 10 ] && [ "$TS_MIN_WINDOW_S" = 195 ] && ok "pinned: 5 %, 10 % of the time (= p90), 195 s" || bad "constants changed: $TS_LIMIT $TS_MAX_SHARE $TS_MIN_WINDOW_S"
RC5="$FX/idle_sup_usec_k31_rc5_45min.txt"; OCT="$FX/idle_sup_usec_k31_gm0252_derived.txt"
o=$(v "$RC5"); r=$?; [ $r = 0 ] && ok "rc5 45 min passes: $o" || bad "rc5 45 min rc=$r: $o"
# every 195 s window (start every 5 s)
grep -v '^#' "$RC5" > "$W/rc5"; total=$(wc -l < "$W/rc5"); i=1; nw=0; nf=0; worst=0
while [ $((i + 200)) -le "$total" ]; do
  o=$(sed -n "${i},$((i + 200))p" "$W/rc5" | ts_verdict 5 10 195); r=$?
  nw=$((nw+1)); [ $r = 0 ] || { nf=$((nf+1)); echo "        window @$i rc=$r: $o"; }
  i=$((i + 5))
done
[ "$nw" -ge 400 ] && [ "$nf" = 0 ] && ok "rc5: all $nw windows of 195 s pass" || bad "rc5: $nf of $nw windows fail"
o=$(v "$OCT"); r=$?; [ $r = 1 ] && ok "gm 0.252 series (October) fails: $o" || bad "October series rc=$r: $o"
awk 'BEGIN{for(i=0;i<=300;i++) print 1800000000+i, i*60000}' > "$W/c6"
o=$(ts_verdict 5 10 195 < "$W/c6"); r=$?; [ $r = 1 ] && ok "constant 6 % fails: $o" || bad "constant 6 % rc=$r: $o"
head -120 "$W/rc5" > "$W/short"; o=$(ts_verdict 5 10 195 < "$W/short"); r=$?; [ $r = 2 ] && ok "120 s cannot judge: $o" || bad "short window rc=$r"
o=$(ts_verdict 5 10 195 < /dev/null); r=$?; [ $r = 2 ] && ok "empty cannot judge" || bad "empty rc=$r"
{ head -100 "$W/rc5"; awk 'NR>100 && NR<=300 {print $1, $2 - 1000000000}' "$W/rc5"; } > "$W/reset"
o=$(ts_verdict 5 10 195 < "$W/reset"); r=$?; [ $r = 2 ] && ok "counter reset cannot judge: $o" || bad "counter reset rc=$r: $o"
# red proof: the old p90-of-12 rule on the same series flips with the phase
f=0; n=0; i=2
while [ $((i + 60)) -le "$total" ]; do
  vals=$(awk -v s="$i" 'NR>=s-1 && NR<s+60 { if (NR>=s && (NR-s)%5==0) printf "%.2f\n", ($2-pu)/1e6/($1-pt)*100; pt=$1; pu=$2 }' "$W/rc5")
  p=$(window_p90 "$vals"); n=$((n+1)); [ "${p:-0}" -ge 5 ] && f=$((f+1)); i=$((i + 7))
done
[ "$f" -gt 0 ] && [ "$f" -lt "$n" ] && ok "old rule on the same rc5 series: $f of $n starts fail (verdict depends on the phase)" || bad "old-rule replay: $f of $n"
grep -q 'ts_verdict "\$TS_LIMIT" "\$TS_MAX_SHARE" "\$TS_MIN_WINDOW_S"' "$SUITE" && grep -q '^\. "\$SCRIPT_DIR/\.\./lib/time_share\.sh"' "$SUITE" \
  && ok "idle_perf judges IDLE-10b with the pinned constants" || bad "IDLE-10b is not judged by time_share.sh"
echo "time_share: $pass passed, $fail failed"; [ "$fail" = 0 ] && [ "$pass" -ge 10 ]
