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
IOD_MASK=254     # 0xFE: bits 1..7 (vccio1..7); bit 0 is pmuio, not judged here
#
# TWO pinned sets since Odoo #1900 (2026-11-11). The vccio5 bank is PHYSICALLY
# 3.3 V (RTL8201F IO = DVDD33; pin 21 measured 3.3 V on two units, #1484). Since
# option B (#1981, Thomas 2026-11-12) a card with NO ga_vccio5 key and one with
# ga_vccio5=3v3 run the 3.3 V DTB; ga_vccio5=1v8 (pinned on field units by the
# RAUC install-check hook before an OTA) and any other value run 1.8 V.
# The MODE (operator intent) picks which pinned set applies; the device is then
# judged against it. Both sets are measurements, never read from the DT under test:
#   1v8  0x140=0xA6, vccio5 -> vcc_1v8   K170/K31 2026-11-05, iHost-A 2026-11-11
#   3v3  0x140=0x86, vccio5 -> vcc_3v3   iHost-A/-B 2026-11-11
# Pin drive (IOD-06) is the SAME in both modes: 83/84/86 = 12 mA, MDC pin 82 = 2 mA,
# measured on iHost-A in both modes and iHost-B at 3v3 (REAL captures). The earlier
# "pin 82 = 4 mA" came from a MODELLED fixture and could not pass on iHost-A.
IOD_BOOTCFG="${IOD_BOOTCFG:-/mnt/boot/haos-config.txt}"

# iod_mode <haos-config.txt> — print 3v3 exactly when boot.scr would load the 3.3 V
# DTB, else 1v8 (absent key, absent file = a legacy device). It MIRRORS U-Boot:
# `env import -t` keeps the LAST value of a key, and hush compares
# "x${ga_vccio5}" = "x3v3" exactly, so a trailing space or CR, or a later
# ga_vccio5=1v8 line, means 1v8 to the bootloader and therefore here too
# (tests/gates/ihost_vccio5_bootscr evaluates that boot.scr block).
iod_mode() {   # mirrors uboot-boot.ush (Odoo #1981, option B): the LAST value wins
  _v=""
  [ -r "$1" ] && _v=$(sed -n 's/^ga_vccio5=//p' "$1" | tail -n1)
  case "$_v" in
    1v8) echo 1v8 ;;
    3v3|"") echo 3v3 ;;     # no key (or an empty value) = the image default, 3.3 V
    *) echo 1v8 ;;          # any other value (CRLF, spaces, garbage): boot.scr loads 1.8 V
  esac
}

# iod_set_mode <1v8|3v3> — load the pinned expectations of that mode.
iod_set_mode() {
  case "$1" in
    3v3) IOD_MODE=3v3; IOD_EXPECT=134; IOD_EXPECT_HEX=0x86; IOD_V5_SUPPLY=vcc_3v3 ;;
    *)   IOD_MODE=1v8; IOD_EXPECT=166; IOD_EXPECT_HEX=0xA6; IOD_V5_SUPPLY=vcc_1v8 ;;
  esac
}
iod_set_mode 1v8

# iod_loaded <cmdline-file> — the DTB variant boot.scr actually loaded, from the
# kernel argument ga.vccio5=<3v3|1v8> (uboot-boot.ush, Odoo #1900). Prints "none"
# for a boot script that predates the argument.
iod_loaded() {
  _a=$(tr ' ' '\n' < "$1" 2>/dev/null | sed -n 's/^ga\.vccio5=//p' | tail -n1)
  echo "${_a:-none}"
}

# iod_loaded_verdict <mode> <loaded> — rc 0 when the loaded DTB matches the mode.
# A requested 3v3 that booted 1v8 is the silent-fallback case: FAIL, loudly.
iod_loaded_verdict() {
  case "$1:$2" in
    3v3:3v3|1v8:1v8) echo "mode $1, boot.scr loaded the $2 DTB"; return 0 ;;
    3v3:1v8) echo "ga_vccio5=3v3 requested but boot.scr loaded the 1v8 DTB (3v3 file missing? see the U-Boot console)"; return 1 ;;
    *:none)  echo "no ga.vccio5= on the kernel command line — boot.scr predates #1900, cannot tell which DTB loaded"; return 1 ;;
    *)       echo "mode $1 but boot.scr loaded '$2'"; return 1 ;;
  esac
}
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
  [ "$_bad" -eq 0 ] && printf 'bits 1-7 of 0x140 = 0x%02X = pinned %s (%s)\n' "$_got" "$IOD_EXPECT_HEX" "$IOD_MODE"
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
  awk -v v5="$IOD_V5_SUPPLY" '
    function want(n) { return (n==5) ? v5 : ((n==3||n==4||n==6) ? "vcc_3v3" : "") }
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
      if (!bad) printf "%d io-domains consumers listed; vccio5 under %s, vccio3/4/6 under vcc_3v3\n", seen, v5
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

# iod_pinconf_verdict <file> — pins 83,84,86 = 12 mA, pin 82 = 2 mA (PINNED, both modes).
iod_pinconf_verdict() {
  _bad=0
  for _pe in 83:12 84:12 86:12 82:2; do
    _pn=${_pe%%:*}; _pw=${_pe##*:}
    if _pg=$(iod_pinconf_ma "$1" "$_pn"); then
      [ "$_pg" -eq "$_pw" ] || { printf 'pin %s drives %s mA, known-good is %s mA\n' "$_pn" "$_pg" "$_pw"; _bad=1; }
    else
      printf 'pin %s: no mA figure in %s (fail closed)\n' "$_pn" "$1"; _bad=1
    fi
  done
  [ "$_bad" -eq 0 ] && echo "pins 83/84/86 = 12 mA, pin 82 = 2 mA"
  return "$_bad"
}

# iod_klog_capture <out-file> — the kernel log of the WHOLE current boot (Odoo #1961).
# The io-domain driver reports at boot; dmesg is a ring buffer, and reading
# debugfs pinconf-pins (IOD-06) writes one "unsupported pinctrl" line per pin —
# 4,349 on iHost-B rc13 (2026-11-12) — so after IOD-06 the buffer started at 420 s
# and the boot was gone. The journal keeps the whole boot: prefer it; fall back to
# dmesg only where there is no journal. Prints the source used; rc 1 = no capture.
iod_klog_capture() {
  if command -v journalctl >/dev/null 2>&1 && journalctl -k -b 0 --no-pager > "$1" 2>/dev/null && [ -s "$1" ]; then
    echo journal; return 0
  fi
  dmesg > "$1" 2>/dev/null && [ -s "$1" ] && { echo dmesg; return 0; }
  return 1
}

# iod_dmesg_verdict <kernel-log-file> — none of IOD_DMESG_BAD, AND the capture
# reaches back to the boot ("Booting Linux" line). An empty/unreadable capture
# FAILS, and so does one that does not start at the boot: a rotated ring buffer
# with no error in it proves nothing about the boot (Odoo #1961).
iod_dmesg_verdict() {
  [ -s "$1" ] || { echo "kernel log capture empty or unreadable — nothing inspected"; return 1; }
  _h=$(grep -E "$IOD_DMESG_BAD" "$1" | head -n3)
  [ -z "$_h" ] || { printf '%s\n' "$_h"; return 1; }
  grep -q "Booting Linux" "$1" || { echo "kernel log does not reach back to the boot (no \"Booting Linux\" line — ring buffer rotated?): boot-time io-domain errors would be invisible"; return 1; }
  echo "no io-domain error strings in the kernel log of the whole boot"; return 0
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
