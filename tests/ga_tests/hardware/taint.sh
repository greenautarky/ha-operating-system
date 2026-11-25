#!/bin/sh
# taint.sh - HW-12's verdict, in one place so the host selftest drives the LIVE function.
#
# /proc/sys/kernel/tainted must be 0, with ONE known exception: exactly 512 (bit 9,
# TAINT_WARN) when the kernel log of this boot holds the known boot-time WARN of the
# Rockchip power-domain probe - a WARNING block whose trace names BOTH
# rockchip_pm_domain_probe and clk_bulk_put. Every other taint bit, any WARNING block
# without that signature, any BUG/Oops, and a log that no longer reaches back to the boot
# (the WARN cannot be attributed, so it cannot be excused) stay RED.
#
#   hw_taint_verdict <tainted-value>   kernel log on stdin; message on stdout; rc 0 = pass

hw_taint_verdict() {
  _t="$1"
  _log=$(cat)
  case "$_t" in ''|*[!0-9]*) echo "cannot read /proc/sys/kernel/tainted ('$_t')"; return 1 ;; esac
  [ "$_t" = 0 ] && { echo "kernel not tainted"; return 0; }
  [ "$_t" = 512 ] || { echo "kernel tainted with $_t (only 512 = TAINT_WARN from the known Rockchip power-domain WARN is accepted)"; return 1; }
  printf '%s\n' "$_log" | grep -q "Booting Linux" || { echo "tainted 512 (WARN) but the kernel log no longer reaches back to the boot (no \"Booting Linux\"): the WARN cannot be attributed - reboot and re-run"; return 1; }
  printf '%s\n' "$_log" | grep -qE 'BUG:|Oops|Kernel panic' && { echo "tainted 512 and the kernel log holds a BUG/Oops/panic"; return 1; }
  # one WARNING block = from a "WARNING:" line to its "end trace" line (or the end of the log)
  _res=$(printf '%s\n' "$_log" | awk '
    function close_block() { if (inb) { n++; if (pd && cb) ok++; inb = 0; pd = 0; cb = 0 } }
    /WARNING:/ { close_block(); inb = 1 }
    inb && /rockchip_pm_domain_probe/ { pd = 1 }
    inb && /clk_bulk_put/ { cb = 1 }
    inb && /end trace/ { close_block() }
    END { close_block(); printf "%d %d\n", n + 0, ok + 0 }')
  set -- $_res
  if [ "$1" -eq 0 ]; then echo "tainted 512 (WARN) but no WARNING block in the kernel log of this boot: nothing to attribute it to"; return 1; fi
  if [ "$1" -ne "$2" ]; then echo "tainted 512: $1 WARNING block(s), only $2 carry the known rockchip_pm_domain_probe / clk_bulk_put signature"; return 1; fi
  echo "tainted 512 = the known boot WARN (rockchip_pm_domain_probe / clk_bulk_put), $1 block(s), nothing else"
  return 0
}
