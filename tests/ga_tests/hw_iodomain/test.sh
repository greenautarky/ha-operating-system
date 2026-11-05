#!/bin/sh
# hw_iodomain — the iHost I/O-domain voltages the RUNNING kernel programmed.
#
# Why: BOSv1.6.0-rc1 declared vccio5 as 3.3 V; the register read 0x86 instead of
# 0xA6 and Ethernet died on a unit with a working PHY — while the image built and
# every other suite was green. Decision 2026-11-05: every image must set the
# correct settings; verifying that on the bench canary each time is enough. This suite runs on
# the device (run_all.sh device lane = the bench canary regression run).
#
#   IOD-01  PMUGRF 0x140 bits 1-7 == the PINNED 0xA6 (see iodomain.sh)
#   IOD-02  the running DT's vccio5-supply resolves to the regulator "vcc_1v8"
# Fail closed: an unreadable regmap / missing 140 line is a FAIL, not a skip.
# Other boards: skipped with the reason (the register map is RV1126-specific).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
. "$SCRIPT_DIR/iodomain.sh"

suite_start "iHost I/O-domain voltages (PMUGRF 0x140)"

if ! iod_is_ihost "$IOD_DTBASE/compatible"; then
  skip_test "IOD-01" "PMUGRF 0x140 == 0xA6" "not a Sonoff iHost ($(tr '\0' ' ' < "$IOD_DTBASE/compatible" 2>/dev/null))"
  skip_test "IOD-02" "vccio5-supply is vcc_1v8" "not a Sonoff iHost"
else
  if _val=$(iod_read140 "$IOD_REGMAP"); then
    _msg=$(iod_verdict "$_val"); _rc=$?
    show_verdict "IOD-01" "PMUGRF 0x140 bits 1-7 equal the pinned 0xA6 (raw 0x$(printf %02X "$_val"))" "$_rc" "$_msg"
  else
    show_verdict "IOD-01" "PMUGRF 0x140 bits 1-7 equal the pinned 0xA6" 1 \
      "cannot read line '140:' from $IOD_REGMAP (debugfs not mounted or regmap renamed) — NOT evidence the voltages are right"
  fi

  _iod=$(find "$IOD_DTBASE" -maxdepth 3 -type d -name io-domains 2>/dev/null | head -n1)
  _name=$(iod_supply_name "$IOD_DTBASE" "${_iod#"$IOD_DTBASE"/}/vccio5-supply"); _rc=$?
  if [ "$_rc" -eq 0 ] && [ "$_name" != vcc_1v8 ]; then _rc=1; _name="vccio5-supply resolves to '$_name', expected 'vcc_1v8'"; fi
  [ "$_rc" -eq 0 ] && _name="vccio5-supply -> $_name"
  show_verdict "IOD-02" "running DT: vccio5-supply resolves to the regulator vcc_1v8" "$_rc" "$_name"
fi

suite_end
