#!/bin/sh
# make-vccio5-3v3-dtb.sh <in.dtb> <out.dtb>
#
# Derive the iHost "vccio5 = 3.3 V" device tree from the built legacy DTB by
# changing exactly ONE property: io-domains/vccio5-supply -> the vcc_3v3 regulator.
#
# Why (Odoo #1484 / #1900, measured 2026-11-11): the RMII/MDIO bank VCCIO5 is
# physically 3.3 V (RTL8201F IO = DVDD33; PHYRSTB measured 3.3 V on two units).
# GA images declared it 1.8 V since 3c8c6f49d (2026-03-11). A unit that ran the
# 1.8 V setting lost its PHY in the correct 3.3 V setting; a fresh unit works at
# 3.3 V. Decision Thomas 2026-11-11: freshly flashed devices (the flasher writes
# ga_vccio5=3v3 into haos-config.txt) boot this DTB; every other device keeps the
# legacy one. boot.scr picks the file (uboot-boot.ush).
#
# Tools: FDTGET, FDTPUT, DTC (default: from PATH). The image build passes the
# host-dtc binaries from ${HOST_DIR}/bin. Fails closed on every surprise:
#   - the base DTB's vccio5-supply is not the vcc_1v8 phandle
#   - a symbol (pmu_io_domains / vcc_3v3 / vcc_1v8) is missing
#   - after the edit the property is not the vcc_3v3 phandle
#   - the decompiled trees differ in anything but that one line
set -eu

die() { echo "make-vccio5-3v3-dtb: ERROR: $*" >&2; rm -f "${out:-/nonexistent}.tmp"; exit 1; }

[ $# -eq 2 ] || die "usage: $0 <in.dtb> <out.dtb>"
in=$1; out=$2
G=${FDTGET:-fdtget}; P=${FDTPUT:-fdtput}; D=${DTC:-dtc}
for t in "$G" "$P" "$D"; do command -v "$t" >/dev/null 2>&1 || die "tool '$t' not found"; done
[ -r "$in" ] || die "cannot read $in"

iod=$("$G" "$in" /__symbols__ pmu_io_domains 2>/dev/null) || die "no symbol pmu_io_domains in $in (built without -@?)"
n33=$("$G" "$in" /__symbols__ vcc_3v3 2>/dev/null)        || die "no symbol vcc_3v3 in $in"
n18=$("$G" "$in" /__symbols__ vcc_1v8 2>/dev/null)        || die "no symbol vcc_1v8 in $in"
p33=$("$G" -t x "$in" "$n33" phandle 2>/dev/null)        || die "vcc_3v3 ($n33) has no phandle"
p18=$("$G" -t x "$in" "$n18" phandle 2>/dev/null)        || die "vcc_1v8 ($n18) has no phandle"
[ "$p33" != "$p18" ] || die "vcc_3v3 and vcc_1v8 share phandle $p33"

cur=$("$G" -t x "$in" "$iod" vccio5-supply 2>/dev/null)  || die "$iod has no vccio5-supply"
[ "$cur" = "$p18" ] || die "base DTB vccio5-supply = $cur, expected the vcc_1v8 phandle $p18 — the base must stay the legacy 1.8 V DTB"

cp "$in" "$out.tmp"
"$P" -t x "$out.tmp" "$iod" vccio5-supply "$p33" || die "fdtput failed"
new=$("$G" -t x "$out.tmp" "$iod" vccio5-supply) || die "cannot read back vccio5-supply"
[ "$new" = "$p33" ] || die "read back vccio5-supply = $new, expected $p33"

# Exactly one line of the decompiled tree may differ, and it must be vccio5-supply.
a=$("$D" -q -I dtb -O dts "$in" 2>/dev/null) || die "dtc cannot decompile $in"
b=$("$D" -q -I dtb -O dts "$out.tmp" 2>/dev/null) || die "dtc cannot decompile the result"
d=$(printf '%s\n' "$a" > "$out.a"; printf '%s\n' "$b" > "$out.b"; diff "$out.a" "$out.b" | grep '^[<>]' || true)
rm -f "$out.a" "$out.b"
nd=$(printf '%s\n' "$d" | grep -c '^[<>]' || true)
[ "$nd" -eq 2 ] || die "expected exactly 2 diff lines (one property), got $nd:
$d"
printf '%s\n' "$d" | grep -q '^>.*vccio5-supply' || die "the differing line is not vccio5-supply:
$d"

mv "$out.tmp" "$out"
echo "make-vccio5-3v3-dtb: $(basename "$out"): vccio5-supply $p18 (vcc_1v8) -> $p33 (vcc_3v3), 1 property changed"
