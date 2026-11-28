#!/bin/sh
# board_expect.sh - what the hardware suite expects per board (pinned constants, never read from the
# device's own board file). Keyed on the CPU arch, as versions_running is.
#   hw_board_expect <uname -m>   sets HW_WIFI_MOD HW_ETH HW_OOT; rc 1 = unknown board
# HW_OOT: the one out-of-tree module the board's image loads (TAINT_OOT = 4096).
hw_board_expect() {
  HW_WIFI_MOD=; HW_ETH=; HW_OOT=
  case "$1" in
    armv7l)  HW_WIFI_MOD=rtw88_8723ds; HW_ETH=eth0 ;;
    aarch64) HW_WIFI_MOD=rtw88_8821cs; HW_ETH=end0; HW_OOT=ga_wlan_platdata ;;
    *) return 1 ;;
  esac
}

# hw_taint_oot_verdict <tainted> <expected module> [sysfs module dir]
# rc 0 = exactly 4096 and the expected module is the ONLY one flagged O (its taint is exactly "O").
# rc 1 = anything else. Message on stdout.
hw_taint_oot_verdict() {
  _d="${3:-/sys/module}"
  [ -n "$2" ] && [ "$1" = 4096 ] || { echo "tainted $1: not the single out-of-tree taint of this board"; return 1; }
  _l=""
  for _m in "$_d"/*/taint; do
    [ -r "$_m" ] || continue
    _v=$(cat "$_m" 2>/dev/null); [ -n "$_v" ] || continue
    _n=${_m%/taint}; _l="$_l ${_n##*/}:$_v"
  done
  [ "$_l" = " $2:O" ] && { echo "tainted 4096 = only $2 (out-of-tree, shipped by this board's image)"; return 0; }
  echo "tainted 4096 but the flagged modules are:${_l:- none} (expected only $2:O)"; return 1
}
