#!/bin/sh
# wifi_probe.sh — how HW-02/HW-02b read the RTL8723DS probe, in one place so a
# host-side fixture suite can drive the LIVE definition (tests/ga_tests/
# wifi_probe_verdict) instead of a copy of it.
#
# Two facts, two lifetimes — that is the whole point of the split:
#
#   "the driver is loaded"        is DURABLE: /sys/module/rtw88_8723ds exists
#                                for as long as the module is loaded.
#   "the probe logged no error"   is VOLATILE: it lives only in the kernel log,
#                                and both kernel logs on this device age out.
#
# The old single check read the second and reported it as the first, so a
# healthy device went red once its logs had rotated past boot. Measured on K31
# on 2026-09-23 at 21 h uptime: `journalctl -k -b` returned 197 lines whose
# oldest entry was 59 minutes old, 0 of them mentioning the driver, while
# `dmesg` still carried `[6.311479] rtw_8723ds mmc1:0001:1: Firmware version
# 48.0.0` — and /sys/module/rtw88_8723ds was there all along.
#
# And that measurement names a second defect in the old form:
#
#   K=$(journalctl -k -b …); [ -n "$K" ] || K=$(dmesg)
#
# the fallback is gated on "the journal returned SOMETHING", not on "the journal
# returned what we are looking for". A journal that is non-empty but has rotated
# past boot therefore SHADOWS a dmesg that still has the evidence — which is
# exactly the state K31 was in. So wifi_kernel_log concatenates both sources
# rather than choosing between them.

# wifi_kernel_log — every kernel log this device has, concatenated.
wifi_kernel_log() {
  journalctl -k -b --no-pager -q 2>/dev/null
  dmesg 2>/dev/null
}

# wifi_probe_verdict — reads a kernel log on stdin, prints exactly one word:
#
#   clean      the log reaches back to the driver's own probe line, and no
#              eFuse dump failed
#   efuse      it reaches back, and an eFuse dump failed  → a real defect
#   uncovered  the driver's probe line is not in the log at all
#
# `uncovered` is deliberately NOT a failure and NOT a pass. Read together with
# HW-02: if the module is loaded and its probe line is gone from every log, the
# log has aged past boot and this device cannot answer the question any more —
# "I could not see" is the honest answer, and a SKIP is how the suite says it.
# If the module is NOT loaded either, HW-02 is the check that goes red, and it
# goes red on the durable fact rather than on a log's retention.
wifi_probe_verdict() {
  _wpv_log=$(cat)
  if ! printf '%s\n' "$_wpv_log" | grep -qE 'rtw_8723ds|rtw88_8723ds'; then
    echo uncovered
    return 0
  fi
  if printf '%s\n' "$_wpv_log" | grep -qi 'failed to dump efuse'; then
    echo efuse
    return 0
  fi
  echo clean
}
