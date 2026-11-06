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

# ---------------------------------------------------------------------------
# IOD-03 .. IOD-08. Every expectation below is a PINNED constant: the measured
# known-good state of two production-class units on BOSv1.5.3 (hardware
# investigation of 2026-11-05, details kept in the private docs). They are never
# derived from the device tree under test.
# ---------------------------------------------------------------------------
IOD_GRF_REGMAP="${IOD_GRF_REGMAP:-/sys/kernel/debug/regmap/dummy-syscon@0xfe000000/registers}"
IOD_REGSUM="${IOD_REGSUM:-/sys/kernel/debug/regulator/regulator_summary}"
IOD_PINCONF="${IOD_PINCONF:-}"   # empty = glob /sys/kernel/debug/pinctrl/*/pinconf-pins
IOD_RET_EXPECT=65535             # 0xFFFF: PMUGRF 0x144 retention
IOD_PHY_ID_EXPECT="0x001cc816"
IOD_DMESG_BAD="Couldn't write to GRF|Can't determine voltage|May damage SoC"

# iod_readreg <regmap-file> <hex-offset> — decimal value of the FIRST window that
# carries the offset. debugfs regmap dumps alias every 0x1000, so only the first
# match (lowest address == the offset itself) counts. rc 1 = unreadable/absent.
iod_readreg() {
  [ -r "$1" ] || return 1
  # sed, not `while read < file`: a shell `read` fetches the debugfs file in tiny
  # chunks and gets nothing back from it on the device (measured on K31 BOSv1.6.0-rc2,
  # 2026-11-06), while sed reads in blocks. The offset column is zero-padded to the
  # register width (3 digits for PMUGRF, 5 for GRF) — strip the zeros in the pattern.
  _v=$(sed -n "s/^0*$2:[[:space:]]*\\([0-9a-fA-F][0-9a-fA-F]*\\).*/\\1/p" "$1" | head -n1)
  [ -n "$_v" ] || return 1
  echo $((0x$_v))
}

# iod_ret_verdict <dec> — PMUGRF 0x144 (IO retention) must equal 0xFFFF.
iod_ret_verdict() {
  [ "$1" -eq "$IOD_RET_EXPECT" ] && { printf '0x144 = 0x%X = pinned 0xFFFF\n' "$1"; return 0; }
  printf '0x144 = 0x%X, known-good is 0xFFFF\n' "$1"; return 1
}

# iod_rmii_verdict <dec> — GRF 0x70: bit6 set, bit4 clear (RMII interface select).
iod_rmii_verdict() {
  _b6=$(( ($1 >> 6) & 1 )); _b4=$(( ($1 >> 4) & 1 ))
  if [ "$_b6" -eq 1 ] && [ "$_b4" -eq 0 ]; then
    printf 'GRF 0x70 = 0x%X: bit6 set, bit4 clear (RMII)\n' "$1"; return 0
  fi
  printf 'GRF 0x70 = 0x%X: bit6=%s (want 1), bit4=%s (want 0)\n' "$1" "$_b6" "$_b4"; return 1
}

# iod_regsum_verdict <regulator_summary> — consumer io-domains-vccioN must sit under
# the PINNED supply: vccio5 -> vcc_1v8; vccio3/4/6 -> vcc_3v3. Zero io-domains-*
# consumers listed = FAIL (coverage). Consumers are the more-indented lines.
iod_regsum_verdict() {
  [ -r "$1" ] || { echo "cannot read $1"; return 1; }
  awk '
    function want(n) { return (n==5) ? "vcc_1v8" : ((n==3||n==4||n==6) ? "vcc_3v3" : "") }
    /^[ \t]*-+[ \t]*$/ || /^[ \t]*regulator[ \t]/ { next }
    {
      # A REGULATOR row carries three integer columns (use open bypass) after its
      # name — at any nesting depth (vcc_3v3 sits under vcc3v3_sys under vcc5v0_sys on
      # the iHost). A CONSUMER row has a count and then "0mA". Indentation alone
      # cannot tell them apart.
      if ($2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/) { cur = $1; next }
      if (match($1, /io-domains-vccio[0-9]/)) {
        n = substr($1, RSTART + RLENGTH - 1, 1) + 0; seen++
        w = want(n)
        if (w == "") { next }
        checked[n] = 1
        if (cur != w) { printf "io-domains-vccio%d is under %s, known-good is %s\n", n, cur, w; bad = 1 }
      }
    }
    END {
      if (!seen) { print "no io-domains-* consumer listed — nothing inspected"; exit 1 }
      split("3 4 5 6", req, " ")
      for (i = 1; i <= 4; i++) if (!checked[req[i]]) { printf "io-domains-vccio%s not listed\n", req[i]; bad = 1 }
      if (!bad) printf "%d io-domains consumers listed; vccio5 under vcc_1v8, vccio3/4/6 under vcc_3v3\n", seen
      exit bad
    }' "$1"
}

# iod_pinconf_ma <pinconf-pins-file> <pin> — print the first "<N> mA" on the line
# for that pin; rc 1 when the pin or a mA figure is absent.
iod_pinconf_ma() {
  [ -r "$1" ] || return 1
  _l=$(grep -E "^pin $2 " "$1" | head -n1)
  [ -n "$_l" ] || return 1
  _m=$(printf '%s\n' "$_l" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) mA.*/\1/p')
  [ -n "$_m" ] || return 1
  echo "$_m"
}

# iod_pinconf_verdict <file> — pins 83,84,86 = 12 mA, pin 82 = 4 mA (PINNED).
iod_pinconf_verdict() {
  _bad=0
  for _pe in 83:12 84:12 86:12 82:4; do
    _pn=${_pe%%:*}; _pw=${_pe##*:}
    if _pg=$(iod_pinconf_ma "$1" "$_pn"); then
      [ "$_pg" -eq "$_pw" ] || { printf 'pin %s drives %s mA, known-good is %s mA\n' "$_pn" "$_pg" "$_pw"; _bad=1; }
    else
      printf 'pin %s: no mA figure in %s (fail closed)\n' "$_pn" "$1"; _bad=1
    fi
  done
  [ "$_bad" -eq 0 ] && echo "pins 83/84/86 = 12 mA, pin 82 = 4 mA"
  return "$_bad"
}

# iod_dmesg_verdict <dmesg-text-file> — none of IOD_DMESG_BAD; an empty/unreadable
# capture FAILS (an empty log proves nothing).
iod_dmesg_verdict() {
  [ -s "$1" ] || { echo "dmesg capture empty or unreadable — nothing inspected"; return 1; }
  _h=$(grep -E "$IOD_DMESG_BAD" "$1" | head -n3)
  [ -z "$_h" ] && { echo "no io-domain error strings in dmesg"; return 0; }
  printf '%s\n' "$_h"; return 1
}

# iod_eth_verdict <speed> <duplex> <phy_id> <carrier_changes_before> <after> <rx_before> <rx_after>
iod_eth_verdict() {
  _bad=0
  [ "$1" = 100 ] || { echo "speed $1, expected 100"; _bad=1; }
  [ "$2" = full ] || { echo "duplex $2, expected full"; _bad=1; }
  [ "$3" = "$IOD_PHY_ID_EXPECT" ] || { echo "phy_id $3, expected $IOD_PHY_ID_EXPECT"; _bad=1; }
  [ "$5" -eq "$4" ] || { echo "carrier_changes grew $4 -> $5 (link flapping)"; _bad=1; }
  [ "$7" -gt "$6" ] || { echo "rx_packets did not grow ($6 -> $7)"; _bad=1; }
  [ "$_bad" -eq 0 ] && echo "100/full, PHY $3, link stable, rx growing"
  return "$_bad"
}
