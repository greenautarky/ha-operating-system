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
# the per-board expectations and the out-of-tree taint (LIVE board_expect.sh)
. "$HERE/board_expect.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mods() { rm -rf "$W/m"; mkdir -p "$W/m/clean"; : > "$W/m/clean/taint"; for _x in "$@"; do mkdir -p "$W/m/${_x%%:*}"; echo "${_x#*:}" > "$W/m/${_x%%:*}/taint"; done; }
oot() { # oot <PASS|FAIL> <label> <tainted> <expected module>
  _m=$(hw_taint_oot_verdict "$3" "$4" "$W/m"); [ $? -eq 0 ] && _g=PASS || _g=FAIL; n=$((n+1))
  if [ "$_g" = "$1" ]; then printf '  ok    %-5s %s\n' "$_g" "$2"; else printf '  WRONG %s: got %s - %s\n' "$2" "$_g" "$_m"; bad=$((bad+1)); fi
}
is() { n=$((n+1)); if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; else printf '  WRONG %s: %s want %s\n' "$1" "$2" "$3"; bad=$((bad+1)); fi; }
mods ga_wlan_platdata:O;                oot PASS "dsgw: 4096 = only ga_wlan_platdata (DUT2 dev18)" 4096 ga_wlan_platdata
mods ga_wlan_platdata:O other:O;        oot FAIL "dsgw: a second out-of-tree module" 4096 ga_wlan_platdata
mods other:O;                           oot FAIL "dsgw: another out-of-tree module" 4096 ga_wlan_platdata
mods ga_wlan_platdata:PO;               oot FAIL "dsgw: the module is proprietary too" 4096 ga_wlan_platdata
mods;                                   oot FAIL "dsgw: 4096 but no module is flagged" 4096 ga_wlan_platdata
mods ga_wlan_platdata:O;                oot FAIL "dsgw: 4608 (WARN on top)" 4608 ga_wlan_platdata
mods ga_wlan_platdata:O;                oot FAIL "ihost: no out-of-tree module is expected" 4096 ""
hw_board_expect armv7l;  is "ihost pins"  "$HW_WIFI_MOD $HW_ETH [$HW_OOT]" "rtw88_8723ds eth0 []"
hw_board_expect aarch64; is "dsgw pins"   "$HW_WIFI_MOD $HW_ETH [$HW_OOT]" "rtw88_8821cs end0 [ga_wlan_platdata]"
hw_board_expect riscv64; is "unknown board is refused" "$?" 1
is "unknown board expects nothing" "$HW_WIFI_MOD$HW_ETH$HW_OOT" ""
grep -q 'hw_board_expect "' "$HERE/test.sh" && grep -q 'hw_taint_oot_verdict "' "$HERE/test.sh"; is "the suite uses board_expect.sh" "$?" 0
[ "$n" -gt 0 ] || { echo "FATAL: nothing inspected"; exit 2; }
echo "--- hardware (HW-12) selftest: $((n - bad))/$n as expected ---"
[ "$bad" -eq 0 ]
