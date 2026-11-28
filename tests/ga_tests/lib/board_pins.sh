#!/bin/sh
# board_pins.sh - network names per board for the device suites. PINNED constants, keyed on the board the
# image was built for (VARIANT_ID); never read from the device's own board file or from what it reports,
# which is what these checks judge. An unknown board pins nothing and every check that needs a pin is RED.
#
#   bp_load <board>        BP_ETH (wired interface), BP_LAN (firewall LAN set); rc 1 = unknown board
#   bp_eth_off             `nmcli -t -f DEVICE,STATE device status` on stdin: BP_ETH is listed and NOT
#                          connected. rc 0 ok, 1 connected, 2 not listed / no pin (cannot judge = red)
#   bp_fw_input_drop       input chain on stdin: BP_ETH is in a drop rule
#   bp_fw_lan_ui           table on stdin: exactly the LAN set is admitted to :80 and :8123
bp_load() {
  BP_ETH=; BP_LAN=
  case "$1" in
    ihost)   BP_ETH=eth0; BP_LAN='"eth0", "wlan0"' ;;
    dsgw210) BP_ETH=end0; BP_LAN='"end0", "wlan0"' ;;
    *) return 1 ;;
  esac
}
bp_eth_off() {
  _bp=$(cat)
  [ -n "$BP_ETH" ] || { echo "no pinned wired interface (unknown board)"; return 2; }
  _bl=$(printf '%s\n' "$_bp" | grep "^$BP_ETH:" | head -n 1)
  [ -n "$_bl" ] || { echo "$BP_ETH is not in the device list: cannot judge"; return 2; }
  case "$_bl" in "$BP_ETH:connected"*) echo "$_bl"; return 1 ;; esac
  echo "$_bl"; return 0
}
bp_fw_input_drop() { [ -n "$BP_ETH" ] && grep -Eq "$BP_ETH.*drop|drop.*$BP_ETH"; }
bp_fw_lan_ui() { [ -n "$BP_LAN" ] && grep -qE "iifname \{ $BP_LAN \} tcp dport \{[^}]*\<80\>[^}]*\<8123\>[^}]*\}"; }
