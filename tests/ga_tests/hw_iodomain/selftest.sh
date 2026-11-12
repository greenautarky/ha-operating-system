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

# --- IOD-03..08 fixtures (live functions from iodomain.sh) ---------------------
for f in grf-rmii-ok grf-rmii-bad ret-ok ret-bad regsum-ok regsum-vccio5-3v3 regsum-none pinconf-ok pinconf-83-4ma pinconf-real-1v8-ihostA dmesg-ok dmesg-grf; do
  [ -f "$FX/$f.txt" ] || { echo "FATAL: fixture $f.txt missing"; exit 1; }
done
for fn in iod_readreg iod_ret_verdict iod_rmii_verdict iod_regsum_verdict iod_pinconf_verdict iod_dmesg_verdict iod_eth_verdict; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: iodomain.sh no longer defines $fn"; exit 1; }
done
flag() { show_verdict "$1" "$2" "$([ "$3" -ne 0 ] && echo 0 || echo 1)" "$4"; }   # must-flag: rc != 0 is the pass
# must-flag FOR A REASON: rc != 0 AND the message names it (a red for the wrong reason is not a pass)
flagr() { show_verdict "$1" "$2" "$([ "$3" -ne 0 ] && printf '%s' "$4" | grep -qF -- "$5" && echo 0 || echo 1)" "$4"; }
# IOD-03 retention
x=$(iod_readreg "$FX/ret-ok.txt" 144); OUT=$(iod_ret_verdict "$x"); RC=$?
show_verdict ISO-15 "0x144 = 0xFFFF passes" "$RC" "$OUT"
x=$(iod_readreg "$FX/ret-bad.txt" 144); OUT=$(iod_ret_verdict "$x"); RC=$?
flag ISO-16 "0x144 = 0xFFFE is flagged" "$RC" "$OUT"
iod_readreg "$FX/regs-no140.txt" 148 >/dev/null; flag ISO-17 "an absent offset FAILS (fail closed)" $? ""
# IOD-01 red proof with the rc1-style capture, through the same reader
x=$(iod_readreg "$FX/regs-86.txt" 140); OUT=$(iod_verdict "$x"); RC=$?
flag ISO-18 "rc1-style capture 0x140=0x86 flagged via iod_readreg" "$RC" "$OUT"
# IOD-04 RMII, first window only
x=$(iod_readreg "$FX/grf-rmii-ok.txt" 70); OUT=$(iod_rmii_verdict "$x"); RC=$?
show_verdict ISO-19 "GRF 0x70 = 0x40 (bit6 set, bit4 clear) passes" "$RC" "$OUT"
x=$(iod_readreg "$FX/grf-rmii-bad.txt" 70); OUT=$(iod_rmii_verdict "$x"); RC=$?
flag ISO-20 "GRF 0x70 = 0x10 flagged — and the aliased 0x1070 window is NOT used" "$RC" "$OUT"
x=$(iod_readreg "$FX/grf-rmii-bad.txt" 70); [ "$x" = 16 ]
show_verdict ISO-21 "iod_readreg returns the first window (0x10), not the alias (0x40)" "$?" "got $x"
iod_rmii_verdict 80 >/dev/null; flag ISO-22 "bit6 + bit4 both set (0x50) flagged" $? ""
# IOD-05 regulator summary
OUT=$(iod_regsum_verdict "$FX/regsum-ok.txt"); RC=$?
show_verdict ISO-23 "regulator_summary known-good passes" "$RC" "$OUT"
OUT=$(iod_regsum_verdict "$FX/regsum-vccio5-3v3.txt"); RC=$?
flag ISO-24 "vccio5 under vcc_3v3 flagged" "$RC" "$OUT"
OUT=$(iod_regsum_verdict "$FX/regsum-none.txt"); RC=$?
flag ISO-25 "zero io-domains consumers FAILS (coverage)" "$RC" "$OUT"
OUT=$(iod_regsum_verdict "$FX/does-not-exist.txt"); RC=$?
flag ISO-26 "unreadable regulator_summary FAILS" "$RC" "$OUT"
# IOD-06 pinconf
OUT=$(iod_pinconf_verdict "$FX/pinconf-real-1v8-ihostA.txt"); RC=$?
show_verdict ISO-27 "REAL pinconf (iHost-A, 1v8) passes" "$RC" "$OUT"
OUT=$(iod_pinconf_verdict "$FX/pinconf-83-4ma.txt"); RC=$?
flag ISO-28 "4 mA on pin 83 flagged" "$RC" "$OUT"
OUT=$(iod_pinconf_verdict "$FX/regs-a6.txt"); RC=$?
flag ISO-29 "a file without the pins FAILS (fail closed)" "$RC" "$OUT"
# IOD-07 dmesg
OUT=$(iod_dmesg_verdict "$FX/dmesg-ok.txt"); RC=$?
show_verdict ISO-30 "clean dmesg passes" "$RC" "$OUT"
OUT=$(iod_dmesg_verdict "$FX/dmesg-grf.txt"); RC=$?
flagr ISO-31 "dmesg with \"Couldn't write to GRF\" flagged for that line" "$RC" "$OUT" "Couldn't write to GRF"
: > "$T/empty"; iod_dmesg_verdict "$T/empty" >/dev/null; flag ISO-32 "empty dmesg FAILS" $? ""
printf 'x Can'"'"'t determine voltage for vccio5\n' > "$T/d2"; iod_dmesg_verdict "$T/d2" >/dev/null; flag ISO-33 "\"Can't determine voltage\" flagged" $? ""
printf 'x May damage SoC\n' > "$T/d3"; iod_dmesg_verdict "$T/d3" >/dev/null; flag ISO-34 "\"May damage SoC\" flagged" $? ""
# IOD-08 ethernet verdict
OUT=$(iod_eth_verdict 100 full 0x001cc816 5 5 100 250); RC=$?
show_verdict ISO-35 "100/full, PHY ok, stable, rx growing passes" "$RC" "$OUT"
iod_eth_verdict 10 full 0x001cc816 5 5 100 250 >/dev/null; flag ISO-36 "speed 10 flagged" $? ""
iod_eth_verdict 100 half 0x001cc816 5 5 100 250 >/dev/null; flag ISO-37 "half duplex flagged" $? ""
iod_eth_verdict 100 full 0x00000000 5 5 100 250 >/dev/null; flag ISO-38 "wrong PHY id flagged" $? ""
iod_eth_verdict 100 full 0x001cc816 5 7 100 250 >/dev/null; flag ISO-39 "carrier_changes growth flagged" $? ""
iod_eth_verdict 100 full 0x001cc816 5 5 100 100 >/dev/null; flag ISO-40 "rx not growing flagged" $? ""
# --- REAL captures from K31 BOSv1.6.0-rc2 (2026-11-06) — the first fixtures that were
# measured, not modelled. They differ from the modelled ones in three ways: offsets are
# zero-padded to the register width (5 digits in GRF), regulators nest three deep
# (vcc_3v3 < vcc3v3_sys < vcc5v0_sys) and consumers carry a "fe020000.syscon:" prefix.
x=$(iod_readreg "$FX/regs-real-pmugrf-k31-rc2.txt" 144); OUT=$(iod_ret_verdict "$x"); RC=$?
show_verdict ISO-41 "REAL pmugrf capture: 0x144 = 0xFFFF read and passes" "$RC" "$OUT"
x=$(iod_readreg "$FX/regs-real-pmugrf-k31-rc2.txt" 140); OUT=$(iod_verdict "$x"); RC=$?
show_verdict ISO-42 "REAL pmugrf capture: 0x140 = 0xA6 passes" "$RC" "$OUT"
x=$(iod_readreg "$FX/regs-real-grf-k31-rc2.txt" 70); OUT=$(iod_rmii_verdict "$x"); RC=$?
show_verdict ISO-43 "REAL grf capture (5-digit offsets): 0x70 = 0x40 read and passes" "$RC" "$OUT"
OUT=$(iod_regsum_verdict "$FX/regsum-real-k31-rc2.txt"); RC=$?
show_verdict ISO-44 "REAL regulator_summary (nested regulators) passes" "$RC" "$OUT"
sed 's/^\( *\)fe020000.syscon:io-domains-vccio5\(.*\)$/\1XX\2/' "$FX/regsum-real-k31-rc2.txt" > "$T/rs-mut"
OUT=$(iod_regsum_verdict "$T/rs-mut"); RC=$?
flag ISO-45 "REAL summary with the vccio5 row removed FAILS (coverage)" "$RC" "$OUT"
_l5=$(grep 'io-domains-vccio5' "$FX/regsum-real-k31-rc2.txt")
awk -v l="$_l5" '/io-domains-vccio5/ {next} {print} /^ +vcc_3v3 / {print l}' "$FX/regsum-real-k31-rc2.txt" > "$T/rs-mut2"
OUT=$(iod_regsum_verdict "$T/rs-mut2"); RC=$?
flag ISO-46 "REAL summary with vccio5 moved under vcc_3v3 flagged" "$RC" "$OUT"
# --- Two modes (Odoo #1900, 2026-11-11). REAL 3v3 captures from the iHost-A bench unit
# (BOSv1.5.3 booted with the 3.3 V DTB): 0x140=0x86, vccio5 under
# vcc_3v3, MDC pin 82 = 2 mA. Each mode must pass its own captures AND flag the other.
for f in regs-real-pmugrf-3v3-ihostA regsum-real-3v3-ihostA pinconf-real-3v3-ihostA pinconf-real-1v8-ihostA; do
  [ -f "$FX/$f.txt" ] || { echo "FATAL: fixture $f.txt missing"; exit 1; }
done
type iod_mode >/dev/null 2>&1 && type iod_set_mode >/dev/null 2>&1 \
  || { echo "FATAL: iodomain.sh no longer defines iod_mode/iod_set_mode"; exit 1; }
printf 'ga_vccio5=3v3\n' > "$T/c1";  M=$(iod_mode "$T/c1");  show_verdict ISO-47 "mode: 'ga_vccio5=3v3' -> 3v3" "$([ "$M" = 3v3 ] && echo 0 || echo 1)" "$M"
: > "$T/c2";                          M=$(iod_mode "$T/c2");  show_verdict ISO-48 "mode: empty haos-config.txt -> 1v8 (legacy)" "$([ "$M" = 1v8 ] && echo 0 || echo 1)" "$M"
M=$(iod_mode "$T/nope");              show_verdict ISO-49 "mode: missing file -> 1v8 (legacy)" "$([ "$M" = 1v8 ] && echo 0 || echo 1)" "$M"
printf 'ga_vccio5=3v3\r\n' > "$T/c3"; M=$(iod_mode "$T/c3");  show_verdict ISO-50 "mode: CRLF value is not exactly 3v3 -> 1v8 (mirrors hush)" "$([ "$M" = 1v8 ] && echo 0 || echo 1)" "$M"
printf 'ga_vccio5=1v8\n' > "$T/c4";  M=$(iod_mode "$T/c4");  show_verdict ISO-51 "mode: 'ga_vccio5=1v8' -> 1v8" "$([ "$M" = 1v8 ] && echo 0 || echo 1)" "$M"
printf '#ga_vccio5=3v3\nxga_vccio5=3v3\n' > "$T/c5"; M=$(iod_mode "$T/c5"); show_verdict ISO-52 "mode: commented / prefixed key is NOT 3v3" "$([ "$M" = 1v8 ] && echo 0 || echo 1)" "$M"
printf 'ga_vccio5=3v3 \n' > "$T/c6"; M=$(iod_mode "$T/c6"); show_verdict ISO-52a "mode: trailing space -> 1v8 (hush compares exactly)" "$([ "$M" = 1v8 ] && echo 0 || echo 1)" "$M"
printf 'ga_vccio5=3v3\nga_vccio5=1v8\n' > "$T/c7"; M=$(iod_mode "$T/c7"); show_verdict ISO-52b "mode: last value wins (env import) -> 1v8" "$([ "$M" = 1v8 ] && echo 0 || echo 1)" "$M"
printf 'ga_vccio5=1v8\nga_vccio5=3v3\n' > "$T/c8"; M=$(iod_mode "$T/c8"); show_verdict ISO-52c "mode: last value wins -> 3v3" "$([ "$M" = 3v3 ] && echo 0 || echo 1)" "$M"
iod_set_mode 3v3
x=$(iod_readreg "$FX/regs-real-pmugrf-3v3-ihostA.txt" 140); OUT=$(iod_verdict "$x"); RC=$?
show_verdict ISO-53 "3v3: REAL 0x140=0x86 passes" "$RC" "$OUT"
x=$(iod_readreg "$FX/regs-real-pmugrf-k31-rc2.txt" 140); OUT=$(iod_verdict "$x"); RC=$?
flag ISO-54 "3v3: REAL 1v8 capture 0xA6 flagged" "$RC" "$OUT"
show_verdict ISO-55 "3v3: 0xA6 names vccio5 1.8 V vs 3.3 V" "$([ "$OUT" = "vccio5: register implies 1.8 V, known-good is 3.3 V" ] && echo 0 || echo 1)" "$OUT"
OUT=$(iod_regsum_verdict "$FX/regsum-real-3v3-ihostA.txt"); RC=$?
show_verdict ISO-56 "3v3: REAL regulator_summary (vccio5 under vcc_3v3) passes" "$RC" "$OUT"
OUT=$(iod_regsum_verdict "$FX/regsum-real-k31-rc2.txt"); RC=$?
flag ISO-57 "3v3: REAL 1v8 regulator_summary flagged" "$RC" "$OUT"
OUT=$(iod_pinconf_verdict "$FX/pinconf-real-3v3-ihostA.txt"); RC=$?
show_verdict ISO-58 "3v3: REAL pinconf (pin 82 = 2 mA) passes" "$RC" "$OUT"
OUT=$(iod_pinconf_verdict "$FX/pinconf-ok.txt"); RC=$?
flag ISO-59 "MODELLED pinconf with pin 82 = 4 mA is flagged (the old expectation)" "$RC" "$OUT"
iod_set_mode 1v8
x=$(iod_readreg "$FX/regs-real-pmugrf-3v3-ihostA.txt" 140); OUT=$(iod_verdict "$x"); RC=$?
flag ISO-60 "1v8: REAL 3v3 capture 0x86 flagged" "$RC" "$OUT"
OUT=$(iod_regsum_verdict "$FX/regsum-real-3v3-ihostA.txt"); RC=$?
flag ISO-61 "1v8: REAL 3v3 regulator_summary flagged" "$RC" "$OUT"
OUT=$(iod_pinconf_verdict "$FX/pinconf-real-3v3-ihostA.txt"); RC=$?
show_verdict ISO-62 "1v8: REAL 3v3 pinconf passes too (pin drive is mode-independent)" "$RC" "$OUT"
# IOD-00 loaded-vs-mode (Odoo #1900)
type iod_loaded >/dev/null 2>&1 && type iod_loaded_verdict >/dev/null 2>&1 || { echo "FATAL: iod_loaded* missing"; exit 1; }
printf 'console=ttyS2 rauc.slot=A usbcore.authorized_default=0 ga.vccio5=3v3\n' > "$T/cl1"; L=$(iod_loaded "$T/cl1")
show_verdict ISO-63 "cmdline ga.vccio5=3v3 read as 3v3" "$([ "$L" = 3v3 ] && echo 0 || echo 1)" "$L"
printf 'console=ttyS2 rauc.slot=A\n' > "$T/cl2"; L=$(iod_loaded "$T/cl2")
show_verdict ISO-64 "cmdline without the argument -> none" "$([ "$L" = none ] && echo 0 || echo 1)" "$L"
OUT=$(iod_loaded_verdict 3v3 3v3); show_verdict ISO-65 "3v3 requested + 3v3 loaded passes" "$?" "$OUT"
OUT=$(iod_loaded_verdict 1v8 1v8); show_verdict ISO-66 "legacy 1v8 + 1v8 loaded passes" "$?" "$OUT"
OUT=$(iod_loaded_verdict 3v3 1v8); flag ISO-67 "3v3 requested but 1v8 loaded (silent fallback) flagged" "$?" "$OUT"
OUT=$(iod_loaded_verdict 1v8 none); flag ISO-68 "pre-#1900 boot.scr (no argument) flagged, not passed" "$?" "$OUT"
OUT=$(iod_loaded_verdict 1v8 3v3); flag ISO-69 "1v8 mode but 3v3 loaded flagged" "$?" "$OUT"
# --- IOD-07 whole-boot coverage (Odoo #1961) -----------------------------------
# IOD-06 reads pinconf-pins, which floods the kernel ring buffer; on iHost-B rc13
# (2026-11-12) dmesg afterwards started at 420 s. A capture that does not reach
# the boot must FAIL, never pass "clean" (red proof against the old verdict: it
# passed exactly this capture).
fl() { _i=0; while [ $_i -lt "$1" ]; do echo "[  420.$_i] rockchip-pinctrl pinctrl: unsupported pinctrl type"; _i=$((_i+1)); done; }
fl 3000 > "$T/k-rotated"                                                   # dmesg after IOD-06: no boot, no error
OUT=$(iod_dmesg_verdict "$T/k-rotated"); flagr ISO-70 "rotated kernel log (no boot) FAILS instead of passing clean" "$?" "$OUT" "does not reach back to the boot"
{ echo "[    0.000000] Booting Linux on physical CPU 0xf00"; echo "[    1.2] rockchip-iodomain: Couldn't write to GRF"; fl 3000; } > "$T/k-boot-err"
OUT=$(iod_dmesg_verdict "$T/k-boot-err"); flagr ISO-71 "boot-time error before a 3000-line flood is still found" "$?" "$OUT" "Couldn't write to GRF"
{ echo "[    0.000000] Booting Linux on physical CPU 0xf00"; fl 3000; } > "$T/k-boot-ok"
OUT=$(iod_dmesg_verdict "$T/k-boot-ok"); show_verdict ISO-72 "whole-boot log with a flood but no error passes" "$?" "$OUT"
# capture source: the journal when there is one, dmesg only without it (fake binaries = the dependencies, not the subject)
mkdir -p "$T/kb1" "$T/kb2"
printf '#!/bin/sh\necho "[ 0.0] Booting Linux on physical CPU 0xf00"\n' > "$T/kb1/journalctl"
printf '#!/bin/sh\necho "[ 420.0] rockchip-pinctrl pinctrl: unsupported pinctrl type"\n' > "$T/kb1/dmesg"; cp "$T/kb1/dmesg" "$T/kb2/dmesg"
chmod +x "$T/kb1/journalctl" "$T/kb1/dmesg" "$T/kb2/dmesg"
SRC=$(PATH="$T/kb1:/usr/bin:/bin" iod_klog_capture "$T/cap1"); RC=$?
show_verdict ISO-73 "capture prefers the journal (whole boot)" "$([ $RC -eq 0 ] && [ "$SRC" = journal ] && grep -q 'Booting Linux' "$T/cap1" && echo 0 || echo 1)" "src=$SRC"
SRC=$(PATH="$T/kb2" iod_klog_capture "$T/cap2"); RC=$?
show_verdict ISO-74 "without a journal: dmesg fallback, and its rotated content then FAILS IOD-07" "$([ $RC -eq 0 ] && [ "$SRC" = dmesg ] && ! iod_dmesg_verdict "$T/cap2" >/dev/null && echo 0 || echo 1)" "src=$SRC"
# test.sh takes the capture BEFORE IOD-06 reads pinconf-pins (the read is what floods the buffer)
_c=$(grep -n 'iod_klog_capture "\$_dm"' "$HERE/test.sh" | head -n1 | cut -d: -f1)
_p=$(grep -n 'iod_pinconf_verdict "\${_pc' "$HERE/test.sh" | head -n1 | cut -d: -f1)
show_verdict ISO-75 "test.sh captures the kernel log before the IOD-06 pinconf read" "$([ -n "$_c" ] && [ -n "$_p" ] && [ "$_c" -lt "$_p" ] && echo 0 || echo 1)" "capture line ${_c:-none}, pinconf line ${_p:-none}"
suite_end
