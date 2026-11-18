#!/bin/sh
# uplink_lte_builtin_device - the DSGW-210's BUILT-IN LTE modem as the fallback uplink
# (Odoo #2176, #1647) ON the device.
#
# The decisions are proven host-side (tests/ga_tests/uplink_ladder against a stub NetworkManager,
# tests/ga_tests/board_conf for the firewall classification). What only the device answers: is the
# modem there, does the SIM register, does the bearer come up on the interface the ladder publishes,
# is that interface closed in the live firewall, and does the whole chain carry traffic when
# Ethernet goes away.
#
# Non-destructive (always runs; SIM-dependent rows SKIP with the reason, never PASS):
#   ULB-01  ModemManager is active
#   ULB-02  ModemManager enumerates a modem
#   ULB-03  the NM modem profile exists, is type gsm, and does NOT pin a carrier APN in the image
#   ULB-04  ga-uplink.json carries the modem object, right keys and types (what ga_manager reads)
#   ULB-05  ...and it says present=true
#   ULB-06  SIM inserted and the modem registered           (SKIP without a SIM)
#   ULB-07  bearer up on a real interface that the status file names   (SKIP without registration)
#   ULB-08  the modem interface is NOT in the live firewall's LAN allowlist, input ends in a drop
# Destructive (GA_TEST_DESTRUCTIVE=1; needs ULB-06 green; a failsafe restores Ethernet whatever happens):
#   ULB-20  Ethernet taken away -> the default route is on the modem interface within the bound
#   ULB-21  ...and the internet answers over it (NM connectivity check = full)
#   ULB-22  ...and ga-uplink.json reports the bearer up
#   ULB-23  Ethernet back -> the default route returns to the wired interface within the bound
#   ULB-24  ...and the internet answers over it
# CAUTION: ULB-20 cuts the wired link. Run it from the serial console or over the mesh; an SSH session
# riding the cable drops, the failsafe timer still restores Ethernet after GA_ULB_FAILSAFE_S.
# iHost: every row SKIPs (the iHost has no built-in modem; its LTE is a dongle: suite lte_standby).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Built-in LTE modem as fallback uplink (Odoo #2176)"

STATUS="${GA_ULB_STATUS:-/mnt/data/supervisor/share/ga-uplink.json}"
PROFILE="${GA_ULB_PROFILE:-DSGW-210 LTE}"
ETH_IF="${GA_ULB_ETH_IF:-end0}"
BOARD="${GA_ULB_BOARD:-$(ga_board)}"
# Ethernet loss -> modem: kernel failover is immediate when the bearer is already up; otherwise the
# ladder needs 3 strikes x 120 s + the bounded bring-up. 3 ticks + slack.
BOUND_S="${GA_ULB_BOUND_S:-540}"
BACK_S="${GA_ULB_BACK_S:-300}"
FAILSAFE_S="${GA_ULB_FAILSAFE_S:-900}"
# a carrier APN in the image would be a defect: the APN is config (/mnt/boot/ga-lte-apn)
PINNED_BAD="${GA_ULB_PINNED_BAD:-internet.telekom}"

ids="ULB-01 ULB-02 ULB-03 ULB-04 ULB-05 ULB-06 ULB-07 ULB-08 ULB-20 ULB-21 ULB-22 ULB-23 ULB-24"
if [ "$BOARD" != dsgw210 ]; then
  for _i in $ids; do
    skip_test "$_i" "built-in LTE modem fallback" "board '${BOARD:-unknown}' has no built-in modem - the iHost LTE is a dongle (suite lte_standby)"
  done
  suite_end
  exit $?
fi

mod() { jq -r "$1" "$STATUS" 2>/dev/null; }
default_if() { ip -4 route show default 2>/dev/null | head -1 | sed -n 's/.* dev \([^ ]*\).*/\1/p'; }
mm_iface() { nmcli -g GENERAL.IP-IFACE device show "$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="gsm"{print $1; exit}')" 2>/dev/null | head -1; }

# --- non-destructive ---------------------------------------------------------------------------
run_test "ULB-01" "ModemManager is active" "[ \"\$(systemctl is-active ModemManager 2>/dev/null)\" = active ]"

MML=$(mmcli -L 2>&1)
if printf '%s' "$MML" | grep -q '/Modem/'; then _rc=0; else _rc=1; fi
show_verdict "ULB-02" "ModemManager enumerates a modem (the Quectel on USB)" "$_rc" "$(printf '%s' "$MML" | head -2 | tr '\n' ' ')"

PT=$(nmcli -g connection.type connection show "$PROFILE" 2>/dev/null | head -1)
APN=$(nmcli -g gsm.apn connection show "$PROFILE" 2>/dev/null | head -1)
if [ "$PT" = gsm ] && [ "$APN" != "$PINNED_BAD" ]; then _rc=0; else _rc=1; fi
show_verdict "ULB-03" "NM profile '$PROFILE' exists (gsm) and the image does not pin a carrier APN" "$_rc" "type='${PT:-none}' apn='${APN:-<auto>}'"

KEYS='(.modem|type)=="object" and (.modem|has("present") and has("registered") and has("bearer_up") and has("iface") and has("state") and has("failed_reason") and has("operator") and has("tech") and has("signal"))'
TYPES='(.modem.present|type)=="boolean" and (.modem.registered|type)=="boolean" and (.modem.bearer_up|type)=="boolean" and (.modem.iface|type)=="string" and (.modem.state|type)=="string" and ((.modem.signal|type)=="number" or (.modem.signal|type)=="null")'
if jq -e "$KEYS and $TYPES" "$STATUS" >/dev/null 2>&1; then _rc=0; else _rc=1; fi
show_verdict "ULB-04" "ga-uplink.json carries the modem object with the keys and types ga_manager reads" "$_rc" "$(jq -c '.modem' "$STATUS" 2>/dev/null)"

if [ "$(mod '.modem.present')" = true ]; then _rc=0; else _rc=1; fi
show_verdict "ULB-05" "...and reports the modem present" "$_rc" "present=$(mod '.modem.present')"

REG=$(mod '.modem.registered'); MST=$(mod '.modem.state'); WHY=$(mod '.modem.failed_reason')
REGISTERED=0
if [ "$REG" = true ]; then
  show_verdict "ULB-06" "SIM inserted and the modem registered on the network" 0 "state=$MST operator=$(mod '.modem.operator') tech=$(mod '.modem.tech') signal=$(mod '.modem.signal')"
  REGISTERED=1
elif [ "$WHY" = sim-missing ] || [ "$MST" = failed ]; then
  skip_test "ULB-06" "SIM registered" "no usable SIM (state=$MST reason=${WHY:---}) - the bench step that needs the SIM"
else
  show_verdict "ULB-06" "SIM inserted and the modem registered on the network" 1 "state=${MST:-unknown} reason=${WHY:---} (SIM present but not registered: APN, coverage or SIM lock)"
fi

IF=$(mod '.modem.iface')
if [ "$REGISTERED" = 1 ]; then
  if [ "$(mod '.modem.bearer_up')" = true ] && [ -n "$IF" ] && [ -d "/sys/class/net/$IF" ]; then _rc=0; else _rc=1; fi
  show_verdict "ULB-07" "bearer up on a real interface the status file names" "$_rc" "bearer_up=$(mod '.modem.bearer_up') iface='$IF' (kernel has it: $([ -d "/sys/class/net/$IF" ] && echo yes || echo no))"
else
  skip_test "ULB-07" "bearer up on the interface named in the status" "modem not registered (ULB-06)"
fi

# The LIVE ruleset: the modem interface must not be among the interfaces the allowlist governs
# (that list is the LAN), and the input chain ends in a default drop.
IFN="${IF:-ppp0}"
RS=$(nft list table inet ga_firewall 2>/dev/null)
if [ -z "$RS" ]; then
  skip_test "ULB-08" "modem interface closed in the live firewall" "firewall table not loaded (marker /mnt/boot/ga-firewall-off, or load failed - suite firewall says which)"
else
  LAN_LINES=$(printf '%s\n' "$RS" | grep -E 'tcp dport .*accept' | grep -c "\"$IFN\"")
  LAST_IN=$(printf '%s\n' "$RS" | awk '/chain input/{c=1} /chain forward/{c=0} c && /^[[:space:]]+[a-z]/ && !/type filter/{l=$0} END{gsub(/^[[:space:]]+/,"",l); print l}')
  if [ "$LAN_LINES" = 0 ] && [ "$LAST_IN" = drop ]; then _rc=0; else _rc=1; fi
  show_verdict "ULB-08" "modem interface '$IFN' is in no service accept rule, input ends in a default drop" "$_rc" "accept rules naming it: $LAN_LINES; last input rule: '$LAST_IN'"
fi

# --- destructive: Ethernet away -> modem -> Ethernet back -----------------------------------------
if ga_destructive "ULB-20..24" "Ethernet down -> LTE within ${BOUND_S}s -> back to Ethernet within ${BACK_S}s"; then
  ETHP=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v d="$ETH_IF" '$2==d{print $1; exit}')
  if [ "$REGISTERED" != 1 ]; then
    for _i in ULB-20 ULB-21 ULB-22 ULB-23 ULB-24; do skip_test "$_i" "Ethernet <-> LTE failover" "needs a registered modem (ULB-06), none here"; done
  elif [ "$(default_if)" != "$ETH_IF" ] || [ -z "$ETHP" ]; then
    show_verdict "ULB-20" "precondition: the device is on Ethernet ($ETH_IF) before the cut" 1 "default route on '$(default_if)', active eth profile '${ETHP:-none}'"
  else
    # failsafe FIRST: whatever happens to this process (an SSH session riding the cable dies), a
    # transient timer brings Ethernet back.
    systemd-run --quiet --unit=ulb-restore-eth --on-active="${FAILSAFE_S}s" nmcli device connect "$ETH_IF" >/dev/null 2>&1
    restore() { nmcli device connect "$ETH_IF" >/dev/null 2>&1; systemctl stop ulb-restore-eth.timer >/dev/null 2>&1; }
    trap restore EXIT INT TERM
    nmcli device disconnect "$ETH_IF" >/dev/null 2>&1
    wait_for "$BOUND_S" "[ \"\$(ip -4 route show default | head -1 | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p')\" = '$IF' ]"
    D=$(default_if)
    if [ "$D" = "$IF" ]; then _rc=0; else _rc=1; fi
    show_verdict "ULB-20" "Ethernet gone: the default route is on the modem interface '$IF' within ${BOUND_S}s" "$_rc" "default route on '${D:-none}'"
    V=$(nmcli networking connectivity check 2>/dev/null | head -1)
    if [ "$V" = full ]; then _rc=0; else _rc=1; fi
    show_verdict "ULB-21" "the internet answers over LTE (NM connectivity check)" "$_rc" "verdict=${V:-none}"
    wait_for 150 "[ \"\$(jq -r '.modem.bearer_up' '$STATUS' 2>/dev/null)\" = true ]"
    if [ "$(mod '.modem.bearer_up')" = true ]; then _rc=0; else _rc=1; fi
    show_verdict "ULB-22" "ga-uplink.json reports the bearer up while on LTE" "$_rc" "rung=$(mod '.rung') bearer_up=$(mod '.modem.bearer_up')"
    restore; trap - EXIT INT TERM
    wait_for "$BACK_S" "[ \"\$(ip -4 route show default | head -1 | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p')\" = '$ETH_IF' ]"
    D=$(default_if)
    if [ "$D" = "$ETH_IF" ]; then _rc=0; else _rc=1; fi
    show_verdict "ULB-23" "Ethernet back: the default route returns to '$ETH_IF' within ${BACK_S}s" "$_rc" "default route on '${D:-none}'"
    V=$(nmcli networking connectivity check 2>/dev/null | head -1)
    if [ "$V" = full ]; then _rc=0; else _rc=1; fi
    show_verdict "ULB-24" "the internet answers over Ethernet again" "$_rc" "verdict=${V:-none}"
  fi
fi

suite_end
