#!/bin/sh
# Host-side selftest of HW-12's verdict (taint.sh, the LIVE function). The known boot WARN
# fixtures are MODELLED on the kernel's WARN format, not real captures: replace warn-known.txt
# with a capture from a fresh boot when one is at hand. Known-good must PASS; every other
# taint bit, any other WARN, a log without the boot, and a missing log must FAIL.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/taint.sh"
FX="$HERE/fixtures"
n=0; bad=0
want() {   # want <PASS|FAIL> <label> <tainted> <file...>
  _w=$1; _l=$2; _t=$3; shift 3
  _m=$(cat "$@" 2>/dev/null | hw_taint_verdict "$_t"); _rc=$?
  [ "$_rc" -eq 0 ] && _g=PASS || _g=FAIL
  n=$((n+1))
  if [ "$_g" = "$_w" ]; then printf '  ok    %-5s %s\n' "$_g" "$_l"; else printf '  WRONG %s: got %s want %s - %s\n' "$_l" "$_g" "$_w" "$_m"; bad=$((bad+1)); fi
}
want PASS "tainted 0, any log"                            0   "$FX/boot-head.txt"
want PASS "tainted 0, empty log"                          0   /dev/null
want PASS "512 + the known WARN (head + warn + noise)"    512 "$FX/boot-head.txt" "$FX/warn-known.txt" "$FX/noise.txt"
want PASS "512 + the known WARN twice"                    512 "$FX/boot-head.txt" "$FX/warn-known.txt" "$FX/warn-known.txt"
want FAIL "512, boot reached, no WARNING block at all"    512 "$FX/boot-head.txt" "$FX/noise.txt"
want FAIL "512 + known WARN + another WARN"               512 "$FX/boot-head.txt" "$FX/warn-known.txt" "$FX/warn-other.txt"
want FAIL "512 + only an unrelated WARN"                  512 "$FX/boot-head.txt" "$FX/warn-other.txt"
want FAIL "512 + clk_bulk_put without rockchip_pm_domain_probe" 512 "$FX/boot-head.txt" "$FX/warn-half.txt"
want FAIL "512 + known WARN but BUG: in the log"          512 "$FX/boot-head.txt" "$FX/warn-known.txt" "$FX/bug.txt"
want FAIL "512 + known WARN, log does not reach the boot" 512 "$FX/warn-known.txt"
want FAIL "512, empty log"                                512 /dev/null
want FAIL "taint 1 (proprietary module)"                  1   "$FX/boot-head.txt" "$FX/warn-known.txt"
want FAIL "taint 513 (bit 0 + WARN)"                      513 "$FX/boot-head.txt" "$FX/warn-known.txt"
want FAIL "taint 4608 (WARN + TAINT_AUX)"                 4608 "$FX/boot-head.txt" "$FX/warn-known.txt"
want FAIL "taint 1024 (not the WARN bit)"                 1024 "$FX/boot-head.txt" "$FX/warn-known.txt"
want FAIL "unreadable taint value"                        ""  "$FX/boot-head.txt"
[ "$n" -gt 0 ] || { echo "FATAL: nothing inspected"; exit 2; }
echo "--- hardware (HW-12) selftest: $((n - bad))/$n as expected ---"
[ "$bad" -eq 0 ]
