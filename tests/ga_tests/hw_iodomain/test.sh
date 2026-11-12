#!/bin/sh
# hw_iodomain — the iHost I/O-domain voltages the RUNNING kernel programmed.
#
# Why: BOSv1.6.0-rc1 declared vccio5 as 3.3 V; the register read 0x86 instead of
# 0xA6 and Ethernet died on a unit with a working PHY — while the image built and
# every other suite was green. Decision 2026-11-05: every image must set the
# correct settings; verifying that on the bench canary each time is enough. This suite runs on
# the device (run_all.sh device lane = the bench canary regression run).
#
#   IOD-00  kernel arg ga.vccio5= (DTB boot.scr loaded) matches the mode — no silent fallback
#   IOD-01  PMUGRF 0x140 bits 1-7 == the PINNED value of the mode (0xA6 for 1v8, 0x86 for 3v3)
#   IOD-02  the running DT's vccio5-supply resolves to vcc_1v8 (1v8) / vcc_3v3 (3v3)
#   Mode = ga_vccio5 in /mnt/boot/haos-config.txt, as boot.scr reads it (option B,
#   #1981): no key / 3v3 = 3v3, 1v8 / anything else = 1v8. See iodomain.sh.
#   IOD-03  PMUGRF 0x144 (retention) == pinned 0xFFFF
#   IOD-04  GRF 0x70 bit6 set, bit4 clear (RMII interface select)
#   IOD-05  regulator_summary: io-domains-vccio5 under vcc_1v8, vccio3/4/6 under vcc_3v3
#   IOD-06  pinconf: gpio2 pins 83/84/86 = 12 mA, pin 82 = 2 mA (both modes, REAL captures)
#   IOD-07  kernel log of the WHOLE boot (journal; captured before IOD-06) free of io-domain errors
#           Known limit (Odoo #1961): run it after a FRESH boot. On a long uptime with a
#           volatile journal, vacuuming can drop the boot lines; IOD-07 then FAILS loudly
#           ("does not reach back to the boot") — fail-closed, never a false green.
#   IOD-08  Ethernet outcome (only with carrier; no carrier = SKIP, never PASS)
# Known-good values: hardware investigation, measured on two units, 2026-11-05.
# Fail closed: an unreadable regmap / missing 140 line is a FAIL, not a skip.
# Other boards: skipped with the reason (the register map is RV1126-specific).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
. "$SCRIPT_DIR/iodomain.sh"

suite_start "iHost I/O-domain voltages (PMUGRF 0x140)"
iod_set_mode "$(iod_mode "$IOD_BOOTCFG")"
echo "  mode: $IOD_MODE (from $IOD_BOOTCFG; expect 0x140=$IOD_EXPECT_HEX, vccio5 -> $IOD_V5_SUPPLY)"

if ! iod_is_ihost "$IOD_DTBASE/compatible"; then
  skip_test "IOD-01" "PMUGRF 0x140 == $IOD_EXPECT_HEX" "not a Sonoff iHost ($(tr '\0' ' ' < "$IOD_DTBASE/compatible" 2>/dev/null))"
  skip_test "IOD-02" "vccio5-supply is $IOD_V5_SUPPLY" "not a Sonoff iHost"
else
  _ld=$(iod_loaded "${IOD_CMDLINE:-/proc/cmdline}")
  _msg=$(iod_loaded_verdict "$IOD_MODE" "$_ld"); _rc=$?
  show_verdict "IOD-00" "boot.scr loaded the DTB the mode asks for [$IOD_MODE]" "$_rc" "$_msg"
  if _val=$(iod_read140 "$IOD_REGMAP"); then
    _msg=$(iod_verdict "$_val"); _rc=$?
    show_verdict "IOD-01" "PMUGRF 0x140 bits 1-7 equal the pinned $IOD_EXPECT_HEX [$IOD_MODE] (raw 0x$(printf %02X "$_val"))" "$_rc" "$_msg"
  else
    show_verdict "IOD-01" "PMUGRF 0x140 bits 1-7 equal the pinned $IOD_EXPECT_HEX [$IOD_MODE]" 1 \
      "cannot read line '140:' from $IOD_REGMAP (debugfs not mounted or regmap renamed) — NOT evidence the voltages are right"
  fi

  _iod=$(find "$IOD_DTBASE" -maxdepth 3 -type d -name io-domains 2>/dev/null | head -n1)
  _name=$(iod_supply_name "$IOD_DTBASE" "${_iod#"$IOD_DTBASE"/}/vccio5-supply"); _rc=$?
  if [ "$_rc" -eq 0 ] && [ "$_name" != "$IOD_V5_SUPPLY" ]; then _rc=1; _name="vccio5-supply resolves to '$_name', expected '$IOD_V5_SUPPLY' [$IOD_MODE]"; fi
  [ "$_rc" -eq 0 ] && _name="vccio5-supply -> $_name"
  show_verdict "IOD-02" "running DT: vccio5-supply resolves to the regulator $IOD_V5_SUPPLY [$IOD_MODE]" "$_rc" "$_name"

  if _val=$(iod_readreg "$IOD_REGMAP" 144); then
    _msg=$(iod_ret_verdict "$_val"); _rc=$?
  else _rc=1; _msg="cannot read offset 144 from $IOD_REGMAP"; fi
  show_verdict "IOD-03" "PMUGRF 0x144 (retention) equals the pinned 0xFFFF" "$_rc" "$_msg"

  if _val=$(iod_readreg "$IOD_GRF_REGMAP" 70); then
    _msg=$(iod_rmii_verdict "$_val"); _rc=$?
  else _rc=1; _msg="cannot read offset 70 from $IOD_GRF_REGMAP"; fi
  show_verdict "IOD-04" "GRF 0x70 bit6 set + bit4 clear (RMII select)" "$_rc" "$_msg"

  _msg=$(iod_regsum_verdict "$IOD_REGSUM"); _rc=$?
  show_verdict "IOD-05" "regulator_summary: io-domains consumers under the pinned supplies" "$_rc" "$_msg"

  # IOD-07's capture is taken HERE, before IOD-06 reads pinconf-pins (that read
  # floods the kernel ring buffer, Odoo #1961); it is the whole boot from the journal.
  _dm=$(mktemp); _dmsrc=$(iod_klog_capture "$_dm") || _dmsrc=none

  _pc="$IOD_PINCONF"
  [ -n "$_pc" ] || _pc=$(ls /sys/kernel/debug/pinctrl/*/pinconf-pins 2>/dev/null | head -n1)
  _msg=$(iod_pinconf_verdict "${_pc:-/nonexistent}"); _rc=$?
  show_verdict "IOD-06" "pinconf: pins 83/84/86 = 12 mA, pin 82 = 2 mA" "$_rc" "$_msg"

  _msg=$(iod_dmesg_verdict "$_dm"); _rc=$?; rm -f "$_dm"
  show_verdict "IOD-07" "kernel log ($_dmsrc) reaches back to the boot and has no io-domain error strings" "$_rc" "$_msg"

  _e=${IOD_NETDIR:-/sys/class/net/eth0}
  if [ "$(cat "$_e/carrier" 2>/dev/null)" = 1 ]; then
    _cc0=$(cat "$_e/carrier_changes"); _rx0=$(cat "$_e/statistics/rx_packets")
    sleep "${IOD_ETH_WINDOW:-30}"
    _msg=$(iod_eth_verdict "$(cat "$_e/speed" 2>/dev/null)" "$(cat "$_e/duplex" 2>/dev/null)" \
      "$(cat "${IOD_PHYID:-/sys/class/mdio_bus/stmmac-0/stmmac-0:00/phy_id}" 2>/dev/null)" \
      "$_cc0" "$(cat "$_e/carrier_changes")" "$_rx0" "$(cat "$_e/statistics/rx_packets")"); _rc=$?
    show_verdict "IOD-08" "Ethernet outcome: 100/full, PHY id, stable link, rx growing" "$_rc" "$_msg"
  else
    skip_test "IOD-08" "Ethernet outcome" "eth0 has no carrier (no cable or dead PHY) — cannot assert an outcome; NOT a pass"
  fi
fi

suite_end
