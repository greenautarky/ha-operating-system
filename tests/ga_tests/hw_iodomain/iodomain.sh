#!/bin/sh
# Parsing + verdict functions of the hw_iodomain suite. SOURCED by test.sh and by
# selftest.sh — the selftest exercises these LIVE functions, never a copy.
#
# Sonoff iHost (RV1126): the I/O-domain voltage select register is PMUGRF
# (syscon @0xfe020000) offset 0x140. The mainline io-domain driver SETS bit N for
# vccioN when its supply is 1.8 V and CLEARS it for 3.3 V. A wrong bit on a bank
# that carries a peripheral breaks it: vccio5 = Ethernet/MDIO/PHY reset (3.3 V
# there left a unit with a working PHY without Ethernet — BOSv1.6.0-rc1 read 0x86).
#
# PINNED expectation, never derived from the device's DT (an audit must not take
# its expected value from the artifact it audits): the measured known-good state
# of BOSv1.5.3 / BOSv1.6.0-rc2 = vccio1 1.8, vccio2 1.8 (vccio_sd at runtime),
# vccio3/4/6 3.3, vccio5 1.8, vccio7 1.8  ->  0xA6 (bits 1,2,5,7). Same set as
# KNOWN_GOOD in scripts/check-ihost-iodomains.py (that one judges the DT sources).
IOD_EXPECT=166   # 0xA6
IOD_MASK=254     # 0xFE: bits 1..7 (vccio1..7); bit 0 is pmuio, not judged here
IOD_REGMAP="${IOD_REGMAP:-/sys/kernel/debug/regmap/dummy-syscon@0xfe020000/registers}"
IOD_DTBASE="${IOD_DTBASE:-/sys/firmware/devicetree/base}"

# iod_read140 <regmap-file> — print the 0x140 value in decimal; rc 1 when the
# file is unreadable or has no 140 line (fail closed, never a default).
iod_read140() {
  [ -r "$1" ] || return 1
  _v=$(sed -n 's/^140:[[:space:]]*\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p' "$1" | head -n1)
  [ -n "$_v" ] || return 1
  echo $((0x$_v))
}

# iod_verdict <decimal-value> — rc 0 when bits 1..7 equal IOD_EXPECT; else rc 1
# and one line per differing vccioN naming the voltage the register implies.
iod_verdict() {
  _got=$(($1 & IOD_MASK)); _n=1; _bad=0
  while [ "$_n" -le 7 ]; do
    _g=$(( (_got >> _n) & 1 )); _e=$(( (IOD_EXPECT >> _n) & 1 ))
    if [ "$_g" -ne "$_e" ]; then
      [ "$_g" -eq 1 ] && _gv="1.8 V" || _gv="3.3 V"
      [ "$_e" -eq 1 ] && _ev="1.8 V" || _ev="3.3 V"
      printf 'vccio%s: register implies %s, known-good is %s\n' "$_n" "$_gv" "$_ev"
      _bad=1
    fi
    _n=$((_n + 1))
  done
  [ "$_bad" -eq 0 ] && printf 'bits 1-7 of 0x140 = 0x%02X = pinned 0xA6\n' "$_got"
  return "$_bad"
}

# iod_supply_name <dtbase> <io-domains-node-relative-prop> — print the
# regulator-name of the node the phandle in <prop> points to; rc 1 if unresolved.
iod_supply_name() {
  _p="$1/$2"
  [ -r "$_p" ] || { echo "no property $2 in the running DT"; return 1; }
  _ph=$(od -An -tx1 -v "$_p" | tr -d ' \n')
  [ -n "$_ph" ] || { echo "empty phandle in $2"; return 1; }
  for _f in $(find "$1" -name phandle 2>/dev/null); do
    [ "$(od -An -tx1 -v "$_f" | tr -d ' \n')" = "$_ph" ] || continue
    _n=""; [ -r "$(dirname "$_f")/regulator-name" ] && _n=$(tr -d '\0' < "$(dirname "$_f")/regulator-name")
    [ -n "$_n" ] && { printf '%s' "$_n"; return 0; }
    echo "phandle 0x$_ph resolves to $(dirname "$_f") without a regulator-name"; return 1
  done
  echo "phandle 0x$_ph resolves to no node"; return 1
}

# iod_is_ihost <compatible-file> — rc 0 on the Sonoff iHost.
iod_is_ihost() { tr '\0' '\n' < "$1" 2>/dev/null | grep -q '^itead,sonoff-ihost$'; }
