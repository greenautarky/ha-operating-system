#!/bin/sh
# vccio5-key.sh — record the per-flash vccio5 decision on an iHost card.
# SOURCED by scripts/verify-sd.sh and by tests/gates/vccio5_key/selftest.sh (the
# selftest drives these LIVE functions, never a copy).
#
# Odoo #1484 / #1900 / #1944: the iHost RMII/MDIO bank VCCIO5 is physically 3.3 V.
# Images with #1900 carry rv1126/rv1109-sonoff-ihost-vccio5-3v3.dtb; boot.scr loads
# it for ga_vccio5=3v3 and, since option B (#1981), also when there is no key;
# ga_vccio5=1v8 keeps the 1.8 V DTB. haos-config.txt belongs to the device and
# survives OTA. Units that ran the 1.8 V setting behave unpredictably at 3.3 V
# (2026-11-11: 2 of 4 lost the PHY), a factory-fresh unit needs 3.3 V. Thomas
# 2026-11-11: "Pflichtangabe je Flash" — the setting is chosen on every flash,
# 3v3 or 1v8, and there is NO default.
#   3v3  needs the variant: an image WITHOUT it (older than #1900) is refused —
#        the card would silently boot 1.8 V.
#   1v8  writes an explicit ga_vccio5=1v8 on any image (jump tests from an old
#        release, N61; a unit whose PHY only works at 1.8 V). boot.scr treats any
#        value other than exactly 3v3 as the legacy DTB.
# ga-flasher-py/setup-scripts/seed-vccio5.sh implements the same contract on a
# FAT image via mtools (the bench has no NOPASSWD mount); this one works on a
# mounted boot partition.

VCC_VARIANT="rv1126-sonoff-ihost-vccio5-3v3.dtb"

# vcc_mode_verdict <do_flash: true|false> <mode> -> prints "" when the run may go
# on, else the refusal. A flash needs an explicit 3v3|1v8; no flash needs nothing.
vcc_mode_verdict() {
  [ "$1" = true ] || return 0
  case "$2" in
    3v3|1v8) ;;
    "") echo "--vccio5 3v3|1v8 is required with --flash — the Ethernet IO setting is decided per flash, there is no default (Odoo #1944). Fresh unit: 3v3. Unit that only works at 1.8 V, or a jump test from an old release: 1v8." ;;
    *)  echo "--vccio5 '$2' is not 3v3|1v8" ;;
  esac
}

# vcc_seed_dir <mounted-hassos-boot-dir> <mode: 3v3|1v8>
#   rc 0  key written (exactly one ga_vccio5=<mode> line, other lines kept)
#   rc 1  no valid mode, 3v3 on an image without the variant (refuse), or a
#         write/read-back error
vcc_seed_dir() {
  _d=$1; _mode=$2
  case "$_mode" in 3v3|1v8) ;; *) echo "vccio5: no valid mode '$_mode' (3v3|1v8, no default)"; return 1 ;; esac
  _key="ga_vccio5=$_mode"
  [ -d "$_d" ] || { echo "vccio5: $_d is not a directory"; return 1; }
  if [ "$_mode" = 3v3 ] && [ ! -f "$_d/$VCC_VARIANT" ]; then
    echo "vccio5: the image has no $VCC_VARIANT (it predates Odoo #1900) — 3v3 would silently boot the LEGACY vccio5 = 1.8 V setting (choose --vccio5 1v8 explicitly for a jump test)"
    return 1
  fi
  _t=$(mktemp) || return 1
  { [ -f "$_d/haos-config.txt" ] && tr -d '\r' < "$_d/haos-config.txt" | grep -v '^[[:space:]]*ga_vccio5=' ; echo "$_key"; } > "$_t"
  cat "$_t" > "$_d/haos-config.txt" || { rm -f "$_t"; echo "vccio5: cannot write $_d/haos-config.txt"; return 1; }
  rm -f "$_t"
  _n=$(tr -d '\r' < "$_d/haos-config.txt" | grep -cx "$_key")
  [ "$_n" = 1 ] || { echo "vccio5: read back $_n '$_key' lines, want 1"; return 1; }
  return 0
}
