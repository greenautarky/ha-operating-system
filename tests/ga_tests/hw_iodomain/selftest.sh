#!/bin/sh
# hw_iodomain selftest — host side, no device. Drives the LIVE functions of
# iodomain.sh (the same file test.sh sources) with fixtures:
#   must-flag  0x86 (vccio5 = 3.3 V, the BOSv1.6.0-rc1 state) -> names vccio5, 3.3 V
#   must-pass  0xA6 (known good); 0xA7 (bit 0 = pmuio is not judged)
#   must-fail  no '140:' line; unreadable file
#   DT         a phandle fixture: vccio5-supply -> vcc_1v8 resolves; -> vcc_3v3 resolves to another name
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/test_helpers.sh"
. "$HERE/iodomain.sh"
suite_start "hw_iodomain selftest (host)"
FX="$HERE/fixtures"
for f in regs-86 regs-a6 regs-no140; do
  [ -f "$FX/$f.txt" ] || { echo "FATAL: fixture $f.txt missing — refusing to pass over nothing"; exit 1; }
done
type iod_read140 >/dev/null 2>&1 && type iod_verdict >/dev/null 2>&1 && type iod_supply_name >/dev/null 2>&1 \
  || { echo "FATAL: iodomain.sh no longer defines the functions under test"; exit 1; }

v() { _x=$(iod_read140 "$1") || { echo "READFAIL"; return 1; }; iod_verdict "$_x"; }

OUT=$(v "$FX/regs-86.txt"); RC=$?
show_verdict ISO-01 "0x86 is flagged" "$([ $RC -ne 0 ] && echo 0 || echo 1)" "$OUT"
show_verdict ISO-02 "0x86 names vccio5 and 3.3 V as the difference" \
  "$([ "$OUT" = "vccio5: register implies 3.3 V, known-good is 1.8 V" ] && echo 0 || echo 1)" ""
OUT=$(v "$FX/regs-a6.txt"); RC=$?
show_verdict ISO-03 "0xA6 passes" "$RC" "$OUT"
OUT=$(iod_verdict 167); RC=$?
show_verdict ISO-04 "0xA7 (pmuio bit set) passes — bit 0 not judged" "$RC" "$OUT"
OUT=$(iod_verdict 164); RC=$?   # 0xA4: vccio1 3.3 V
show_verdict ISO-05 "0xA4 is flagged as vccio1 3.3 V" \
  "$([ $RC -ne 0 ] && [ "$OUT" = "vccio1: register implies 3.3 V, known-good is 1.8 V" ] && echo 0 || echo 1)" "$OUT"
OUT=$(v "$FX/regs-no140.txt"); RC=$?
show_verdict ISO-06 "a regmap without a 140 line FAILS (fail closed)" "$([ $RC -ne 0 ] && echo 0 || echo 1)" "$OUT"
OUT=$(v "$FX/does-not-exist.txt"); RC=$?
show_verdict ISO-07 "an unreadable regmap FAILS (fail closed)" "$([ $RC -ne 0 ] && echo 0 || echo 1)" "$OUT"

# --- DT phandle resolution ---------------------------------------------------
T=$(mktemp -d) || exit 1; trap 'rm -rf "$T"' EXIT
mk() { mkdir -p "$T/$1"; printf '%b' "$2" > "$T/$1/phandle"; [ -n "${3:-}" ] && printf '%s\0' "$3" > "$T/$1/regulator-name"; return 0; }
mk regulators/a '\000\000\000\014' vcc_1v8
mk regulators/b '\000\000\000\015' vcc_3v3
mk regulators/c '\000\000\000\016'
mkdir -p "$T/syscon/io-domains"
printf '\000\000\000\014' > "$T/syscon/io-domains/vccio5-supply"
N=$(iod_supply_name "$T" syscon/io-domains/vccio5-supply); RC=$?
show_verdict ISO-08 "phandle 0xc resolves to vcc_1v8" "$([ $RC -eq 0 ] && [ "$N" = vcc_1v8 ] && echo 0 || echo 1)" "$N"
printf '\000\000\000\015' > "$T/syscon/io-domains/vccio5-supply"
N=$(iod_supply_name "$T" syscon/io-domains/vccio5-supply); RC=$?
show_verdict ISO-09 "phandle 0xd resolves to vcc_3v3 (so test.sh can flag it)" "$([ $RC -eq 0 ] && [ "$N" = vcc_3v3 ] && echo 0 || echo 1)" "$N"
printf '\000\000\000\077' > "$T/syscon/io-domains/vccio5-supply"
N=$(iod_supply_name "$T" syscon/io-domains/vccio5-supply); RC=$?
show_verdict ISO-10 "a dangling phandle FAILS" "$([ $RC -ne 0 ] && echo 0 || echo 1)" "$N"
printf '\000\000\000\016' > "$T/syscon/io-domains/vccio5-supply"
N=$(iod_supply_name "$T" syscon/io-domains/vccio5-supply); RC=$?
show_verdict ISO-11 "a node without regulator-name FAILS" "$([ $RC -ne 0 ] && echo 0 || echo 1)" "$N"
N=$(iod_supply_name "$T" syscon/io-domains/vccio9-supply); RC=$?
show_verdict ISO-12 "a missing property FAILS" "$([ $RC -ne 0 ] && echo 0 || echo 1)" "$N"
printf 'itead,sonoff-ihost\0rockchip,rv1126\0' > "$T/compat"
iod_is_ihost "$T/compat"; RC=$?; show_verdict ISO-13 "board check: iHost recognised" "$RC" ""
printf 'rockchip,rk3568\0' > "$T/compat2"
iod_is_ihost "$T/compat2"; RC=$?; show_verdict ISO-14 "board check: other board not recognised" "$([ $RC -ne 0 ] && echo 0 || echo 1)" ""
suite_end
