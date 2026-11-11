#!/bin/sh
# vccio5-key.sh — mark a freshly flashed iHost card for the vccio5 = 3.3 V DTB.
# SOURCED by scripts/verify-sd.sh and by tests/gates/vccio5_key/selftest.sh (the
# selftest drives these LIVE functions, never a copy).
#
# Odoo #1484 / #1900: the iHost RMII/MDIO bank VCCIO5 is physically 3.3 V. Images
# with #1900 carry rv1126/rv1109-sonoff-ihost-vccio5-3v3.dtb; boot.scr loads it
# only for ga_vccio5=3v3 in haos-config.txt, which belongs to the device and
# survives OTA. Thomas 2026-11-11: no fresh flash may come out on the old 1.8 V
# setting, so a card written from an image WITHOUT the variant is refused,
# except for jump tests (norm N61) that must start from an old release.
# ga-flasher-py/setup-scripts/seed-vccio5.sh implements the same contract on a
# FAT image via mtools (the bench has no NOPASSWD mount); this one works on a
# mounted boot partition.

VCC_KEY="ga_vccio5=3v3"
VCC_VARIANT="rv1126-sonoff-ihost-vccio5-3v3.dtb"

# vcc_seed_dir <mounted-hassos-boot-dir> <allow_pre_1900: 0|1>
#   rc 0  key written (exactly one ga_vccio5=3v3 line, other lines kept)
#   rc 3  image predates #1900 and allow=1: nothing written (caller warns)
#   rc 1  image predates #1900 and allow=0 (refuse), or a write/read-back error
vcc_seed_dir() {
  _d=$1; _allow=$2
  [ -d "$_d" ] || { echo "vccio5: $_d is not a directory"; return 1; }
  if [ ! -f "$_d/$VCC_VARIANT" ]; then
    [ "$_allow" = 1 ] && return 3
    echo "vccio5: the image has no $VCC_VARIANT (it predates Odoo #1900) — a fresh flash must not run the LEGACY vccio5 = 1.8 V setting"
    return 1
  fi
  _t=$(mktemp) || return 1
  { [ -f "$_d/haos-config.txt" ] && tr -d '\r' < "$_d/haos-config.txt" | grep -v '^[[:space:]]*ga_vccio5=' ; echo "$VCC_KEY"; } > "$_t"
  cat "$_t" > "$_d/haos-config.txt" || { rm -f "$_t"; echo "vccio5: cannot write $_d/haos-config.txt"; return 1; }
  rm -f "$_t"
  _n=$(tr -d '\r' < "$_d/haos-config.txt" | grep -cx "$VCC_KEY")
  [ "$_n" = 1 ] || { echo "vccio5: read back $_n '$VCC_KEY' lines, want 1"; return 1; }
  return 0
}
