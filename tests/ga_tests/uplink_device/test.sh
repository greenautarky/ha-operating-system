#!/bin/sh
# uplink_device - the uplink ladder (Odoo #2112, OS #1097) and the OpenStick
# auto-connect back-off (Odoo #2112, OS #1103) ON the device.
#
# The decisions are proven host-side (tests/ga_tests/uplink_ladder, openstick_backoff,
# against a stub NetworkManager). What only a device answers: is it installed, is the
# timer firing, does the REAL status file carry the new fields, and does a HEALTHY device
# stay quiet - a ladder that rescans (radio time, an association drop) on a healthy
# device would be switched off by the first person who sees it.
#
# The real dongle scenarios (stick without WAN, stick appearing later, last rung going
# offline) need bench hardware: tests/ga_tests/uplink_device/BENCH.md, not automatic.
#
#   UPL-01..03  ladder installed, timer active+scheduled, firing (status fresh)
#   UPL-04      ga-uplink.json parses and carries the schema incl. spare / last_rung /
#               searching / last_rescan with the right types
#   UPL-05      healthy device (verdict full): not searching, not on a "last rung", no
#               rescan in the last 10 min (status + journal). Not healthy -> SKIP, never PASS.
#   UPL-10..13  (iHost only) ga-openstick-autoconnect: installed + timer; the back-off
#               file (absent = nothing barred) parses; the script judges with the NM
#               verdict, not a private curl
# DSGW-210: UPL-10..13 are SKIPPED with the reason - the auto-connect script ships in the
# iHost overlay only (buildroot-ihost); the DSGW-210 has no OpenStick radio path.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Uplink ladder + OpenStick back-off on the device (Odoo #2112)"

LADDER="${GA_UPLD_LADDER:-/usr/sbin/ga-uplink-ladder}"
STATUS="${GA_UPLD_STATUS:-/mnt/data/supervisor/share/ga-uplink.json}"
OSC="${GA_UPLD_OSC:-/usr/sbin/ga-openstick-autoconnect}"
BACKOFF="${GA_UPLD_BACKOFF:-/mnt/data/.ga-openstick-backoff}"
UPTIME_FILE="${GA_UPLD_UPTIME_FILE:-/proc/uptime}"
NOW="${GA_UPLD_NOW:-$(date -u +%s)}"
# 120 s tick + accuracy; two periods and slack
MAX_AGE_S=300
BOARD="${GA_UPLD_BOARD:-$(ga_board)}"

iso_age() {   # iso_age <iso8601> -> seconds ago (empty on a parse failure)
  _e=$(printf '%s' "$1" | jq -R 'fromdateiso8601? // empty' 2>/dev/null)
  [ -n "$_e" ] && echo $(( NOW - _e ))
}

run_test "UPL-01" "ga-uplink-ladder is installed and executable" "test -x '$LADDER'"
run_test "UPL-02" "ga-uplink-ladder.timer is ACTIVE" \
  "[ \"\$(systemctl is-active ga-uplink-ladder.timer 2>/dev/null)\" = active ]"
N=$(systemctl show -p NextElapseUSecMonotonic --value ga-uplink-ladder.timer 2>/dev/null)
case "$N" in ""|0|n/a|infinity) _rc=1 ;; *) _rc=0 ;; esac
show_verdict "UPL-03" "the timer has a next elapse scheduled" "$_rc" "next elapse (monotonic)=${N:-empty}"

# OnBootSec=120: a device younger than that has no status file yet; wait, bounded, then assert.
run_test_ready "UPL-04a" "the status file exists" "test -s '$STATUS'" "${GA_DEVT_WAIT_S:-240}" "test -s '$STATUS'"

KEYS='has("rung") and has("verdict") and has("strikes") and has("parked") and has("spare") and has("last_rung") and has("searching") and has("last_rescan") and has("updated_at")'
TYPES='(.last_rung|type)=="boolean" and (.searching|type)=="boolean" and (.strikes|type)=="number" and (.spare|type)=="string" and (.last_rescan|type)=="string" and (.updated_at|type)=="string"'
if jq -e "$KEYS" "$STATUS" >/dev/null 2>&1; then _rc=0; else _rc=1; fi
show_verdict "UPL-04" "ga-uplink.json has the schema incl. spare, last_rung, searching, last_rescan" "$_rc" "$(jq -c 'keys' "$STATUS" 2>/dev/null)"
if jq -e "$TYPES" "$STATUS" >/dev/null 2>&1; then _rc=0; else _rc=1; fi
show_verdict "UPL-04b" "...with the right types (booleans, strikes a number, the rest strings)" "$_rc" "$(jq -c '{strikes,last_rung,searching}' "$STATUS" 2>/dev/null)"

AGE=$(iso_age "$(jq -r '.updated_at // empty' "$STATUS" 2>/dev/null)")
if [ -n "$AGE" ] && [ "$AGE" -ge -30 ] && [ "$AGE" -le "$MAX_AGE_S" ]; then _rc=0; else _rc=1; fi
show_verdict "UPL-04c" "...and is fresh (the ladder rewrites it every tick): <= ${MAX_AGE_S}s" "$_rc" "updated ${AGE:-unparseable}s ago"

# UPL-05: a healthy device must stay quiet. Only meaningful when it IS healthy.
V=$(jq -r '.verdict // empty' "$STATUS" 2>/dev/null)
S=$(jq -r '.strikes // empty' "$STATUS" 2>/dev/null)
if [ "$V" != full ] || [ "$S" != 0 ]; then
  skip_test "UPL-05" "a healthy device does not rescan" "device not healthy right now (verdict=${V:-?} strikes=${S:-?}) - this is the bench scenario, see BENCH.md"
else
  LR=$(jq -r '.last_rung' "$STATUS" 2>/dev/null); SE=$(jq -r '.searching' "$STATUS" 2>/dev/null)
  RS=$(jq -r '.last_rescan // empty' "$STATUS" 2>/dev/null)
  RAGE=""; [ -n "$RS" ] && RAGE=$(iso_age "$RS")
  JR=$(journalctl -t ga-uplink-ladder --since "-10min" --no-pager -q 2>/dev/null | grep -c 'forcing a Wi-Fi rescan')
  if [ "$LR" = false ] && [ "$SE" = false ] && [ "$JR" = 0 ] && { [ -z "$RAGE" ] || [ "$RAGE" -gt 600 ]; }; then _rc=0; else _rc=1; fi
  show_verdict "UPL-05" "healthy (full, 0 strikes): not searching, not last rung, no rescan in 10 min" "$_rc" "last_rung=$LR searching=$SE last_rescan='${RS:-never}' rescan lines in journal=$JR"
fi

# ---------------------------------------------------------------- OpenStick (iHost)
if [ "$BOARD" != ihost ]; then
  for _i in UPL-10 UPL-11 UPL-12 UPL-13; do
    skip_test "$_i" "OpenStick auto-connect back-off" "board '${BOARD:-unknown}' is not an iHost - ga-openstick-autoconnect ships in buildroot-ihost only"
  done
else
  run_test "UPL-10" "ga-openstick-autoconnect is installed and its timer is active" \
    "test -x '$OSC' && [ \"\$(systemctl is-active ga-openstick-autoconnect.timer 2>/dev/null)\" = active ]"

  # The back-off file: "<ssid> TAB <level> TAB <until-epoch>" per line. Absent/empty = nothing barred.
  if [ ! -s "$BACKOFF" ]; then
    show_verdict "UPL-11" "back-off state file: absent/empty = no SSID barred" 0 "no entries in $BACKOFF"
  else
    BAD=$(awk -F'\t' -v now="$NOW" 'NF!=3 || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $2 < 1 || $3 > now + 21600 + 60 {print NR": "$0}' "$BACKOFF" | head -3)
    LINES=$(wc -l < "$BACKOFF")
    if [ -z "$BAD" ]; then _rc=0; else _rc=1; fi
    show_verdict "UPL-11" "back-off state file parses (3 tab fields, level >= 1, bar <= 6 h ahead)" "$_rc" "$LINES line(s)${BAD:+, bad: $BAD}"
  fi

  # static, on the INSTALLED script: it judges by NM's verdict and not by a private curl.
  CODE=$(grep -v '^[[:space:]]*#' "$OSC" 2>/dev/null)
  if printf '%s\n' "$CODE" | grep -q 'networking connectivity check'; then _rc=0; else _rc=1; fi
  show_verdict "UPL-12" "installed script verifies with NM's own probe (networking connectivity check)" "$_rc" ""
  if printf '%s\n' "$CODE" | grep -qw curl; then _rc=1; else _rc=0; fi
  show_verdict "UPL-13" "...and runs no private curl (the verdict the ladder acts on is the only one)" "$_rc" ""
fi

suite_end
