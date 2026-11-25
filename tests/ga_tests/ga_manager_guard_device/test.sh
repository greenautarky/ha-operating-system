#!/bin/sh
# ga_manager_guard_device - ga-manager-guard (Odoo #2166, OS #1100) ON the device.
#
# The host suite tests/ga_tests/ga_manager_guard drives the LIVE script against a
# stub hassio_cli; this suite asks the questions only a device can answer: is the
# unit installed and actually FIRING, does the REAL Supervisor expose the watchdog toggle,
# and does the guard do what it claims against it.
#
# NON-DESTRUCTIVE (always):
#   GMGD-01..05  script + timer + last run: installed, active, scheduled, firing, rc 0
#   GMGD-06      the status JSON, IF present, parses and is not an unresolved fault.
#                NB the guard publishes /share/ga-manager-guard.json ONLY on events
#                (toggle fixed, revived, start failing, deliberate stop). A healthy
#                device never writes it, so "fresh" is not a property of a healthy
#                device - absence is the healthy state and is reported as such.
#   GMGD-07      the Supervisor watchdog toggle of 99f1cad4_ga_manager is ON
#   GMGD-08      `ha addons info --raw-json` exposes .data.watchdog (a boolean) and it is true.
#                (hassio_cli 2025.10.2 has NO `ha addons options`: the toggle is written through
#                the Supervisor API, POST /addons/<slug>/options {"watchdog":true}, and read back
#                through `ha addons info`; no CLI flag is involved)
#   GMGD-09      no guard ERROR in this boot's journal
# DESTRUCTIVE (GA_TEST_DESTRUCTIVE=1; canary only, ~3 min, never during a soak):
#   GMGD-20      toggle off -> one real guard tick turns it ON again, says WARNING
#   GMGD-21      kill -9 gm -> the Supervisor watchdog revives it
#   GMGD-22      deliberate-stop marker + stop -> the guard leaves it stopped
#   GMGD-23      marker removed, still stopped -> the guard starts it, state `revived`
# The destructive cases drive the REAL /usr/sbin/ga-manager-guard by hand with a private
# state directory and GA_GMG_DOWN_S=0 / GA_GMG_SETTLE_S=5 instead of waiting the 10 min
# grace on the timer; every decision is the real script's, against the real Supervisor.
# A trap restores: marker removed, toggle ON, gm started.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "ga-manager-guard on the device (Odoo #2166)"

SLUG="${GA_GMGD_SLUG:-99f1cad4_ga_manager}"
GUARD="${GA_GMGD_BIN:-/usr/sbin/ga-manager-guard}"
SHARE_FILE="${GA_GMGD_SHARE_FILE:-/mnt/data/supervisor/share/ga-manager-guard.json}"
MARKER="${GA_GMGD_MARKER:-/mnt/data/.ga-manager-deliberate-stop}"
UPTIME_FILE="${GA_GMGD_UPTIME_FILE:-/proc/uptime}"
# a tick runs 2 min apart; the first is OnBootSec=3min. Two periods + slack.
MAX_AGE_S=300

addon_json() { ga_hacli addons info "$SLUG" --raw-json 2>/dev/null; }
addon_state() { addon_json | jq -r '.data.state // empty' 2>/dev/null; }
addon_wd()    { addon_json | jq -r '.data.watchdog | tostring' 2>/dev/null; }
# the toggle write, the way the OS reaches the Supervisor: POST /addons/<slug>/options from inside
# hassio_cli (it holds SUPERVISOR_TOKEN; the token is expanded there, never on the host command line)
set_watchdog() {   # set_watchdog <true|false>
  timeout 60 docker exec hassio_cli sh -c 'curl -sf -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" -H "Content-Type: application/json" -d "{\"watchdog\":'"$1"'}" "http://supervisor/addons/'"$SLUG"'/options"' >/dev/null 2>&1
}
uptime_s() { _u=$(cut -d' ' -f1 "$UPTIME_FILE" 2>/dev/null); echo "${_u%%.*}"; }

run_test "GMGD-01" "ga-manager-guard is installed and executable" "test -x '$GUARD'"
run_test "GMGD-02" "ga-manager-guard.timer is ACTIVE (not merely enabled)" \
  "[ \"\$(systemctl is-active ga-manager-guard.timer 2>/dev/null)\" = active ]"

# monotonic timer: NextElapseUSecRealtime is never set for it (see MESH-04)
N=$(systemctl show -p NextElapseUSecMonotonic --value ga-manager-guard.timer 2>/dev/null)
case "$N" in ""|0|n/a|infinity) _rc=1 ;; *) _rc=0 ;; esac
show_verdict "GMGD-03" "the timer has a next elapse scheduled" "$_rc" "next elapse (monotonic)=${N:-empty}"

# is it FIRING? OnBootSec=3min: a device younger than that has not run it yet, so wait
# (bounded) for the first run, then assert for real either way.
guard_ran() { _t=$(systemctl show -p ExecMainExitTimestampMonotonic --value ga-manager-guard.service 2>/dev/null); [ -n "$_t" ] && [ "$_t" != 0 ]; }
if ! wait_for "${GA_DEVT_WAIT_S:-240}" guard_ran; then printf '  (GMGD-04: the first guard run did not appear within %s s - asserting anyway)\n' "${GA_DEVT_WAIT_S:-240}"; fi
T=$(systemctl show -p ExecMainExitTimestampMonotonic --value ga-manager-guard.service 2>/dev/null)
# T is in microseconds: > 2^31 after ~36 min of uptime, so 32-bit shell arithmetic wraps.
# Cut the last six digits textually (microseconds -> seconds) before any arithmetic.
case "$T" in ""|*[!0-9]*|0) T_S= ;; *) if [ "${#T}" -le 6 ]; then T_S=0; else T_S=${T%??????}; fi ;; esac
if [ -n "$T_S" ]; then
  AGE=$(( $(uptime_s) - T_S ))
  if [ "$AGE" -ge 0 ] && [ "$AGE" -le "$MAX_AGE_S" ]; then _rc=0; else _rc=1; fi
  show_verdict "GMGD-04" "the guard ran within the last ${MAX_AGE_S}s (the timer is really firing)" "$_rc" "last run ${AGE}s ago"
else
  show_verdict "GMGD-04" "the guard ran within the last ${MAX_AGE_S}s (the timer is really firing)" 1 "ExecMainExitTimestampMonotonic='${T:-empty}' - never ran"
fi
R=$(systemctl show -p Result -p ExecMainStatus ga-manager-guard.service 2>/dev/null | tr '\n' ' ')
case "$R" in *"Result=success"*"ExecMainStatus=0"*|*"ExecMainStatus=0"*"Result=success"*) _rc=0 ;; *) _rc=1 ;; esac
show_verdict "GMGD-05" "the last guard run ended Result=success, status 0" "$_rc" "$R"

# GMGD-06: the status file is event-only (see header)
if [ ! -e "$SHARE_FILE" ]; then
  show_verdict "GMGD-06" "status JSON: absent = healthy (the guard publishes only on events)" 0 "no $SHARE_FILE - no event since boot"
else
  ST=$(jq -r '.state // "missing"' "$SHARE_FILE" 2>/dev/null)
  TS=$(jq -r '.ts // empty' "$SHARE_FILE" 2>/dev/null)
  case "$ST" in
    watchdog_enabled|revived|deliberately_stopped) _rc=0; _w="an event record, state=$ST ts=$TS" ;;
    start_failing|start_failed|watchdog_set_failed)
      # A fault record stays until the next event, also after a recovery that publishes
      # nothing. It is a finding only while the fault is still true.
      if [ "$ST" = watchdog_set_failed ]; then
        if [ "$(addon_wd)" = true ]; then _rc=0; else _rc=1; fi
      else
        if [ "$(addon_state)" = started ]; then _rc=0; else _rc=1; fi
      fi
      if [ "$_rc" = 0 ]; then _w="state=$ST ts=$TS (stale: the fault is gone)"; else _w="state=$ST ts=$TS (the fault is STILL true)"; fi ;;
    *) _rc=1; _w="unreadable or unknown state '$ST' in $SHARE_FILE" ;;
  esac
  show_verdict "GMGD-06" "status JSON parses and is not an unresolved fault" "$_rc" "$_w"
fi

WD=$(addon_wd)
if [ "$WD" = true ]; then _rc=0; else _rc=1; fi
show_verdict "GMGD-07" "the Supervisor watchdog toggle of $SLUG is ON" "$_rc" "watchdog=$WD state=$(addon_state)"

# The field the guard reads back (and the destructive cases rely on): exposed, boolean, true.
CLI_IMG=$(docker inspect -f '{{.Config.Image}}' hassio_cli 2>/dev/null)
WDT=$(addon_json | jq -r '.data.watchdog | type' 2>/dev/null)
if [ "$WDT" = boolean ] && [ "$WD" = true ]; then _rc=0; else _rc=1; fi
show_verdict "GMGD-08" "'ha addons info --raw-json' exposes .data.watchdog (boolean) and it is true" "$_rc" "type=${WDT:-none} value=$WD; hassio_cli image: ${CLI_IMG:-unknown}"

ERRS=$(journalctl -t ga-manager-guard -p err -b --no-pager -q 2>/dev/null | wc -l)
if [ "$ERRS" = 0 ]; then _rc=0; else _rc=1; fi
show_verdict "GMGD-09" "no guard ERROR in this boot's journal" "$_rc" "$ERRS error line(s)"

# ------------------------------------------------------------------ destructive
if ga_destructive "GMGD-20..23" "toggle repair, kill -9 revive, deliberate stop, guard start net"; then
  TD=$(mktemp -d /mnt/data/tmp/ga-gmgd.XXXXXX 2>/dev/null || mktemp -d /tmp/ga-gmgd.XXXXXX)
  restore() {
    rm -f "$MARKER"
    [ "$(addon_wd)" = true ] || set_watchdog true
    [ "$(addon_state)" = started ] || ga_hacli addons start "$SLUG" >/dev/null 2>&1
    rm -rf "$TD"
  }
  trap restore EXIT INT TERM
  tick() {   # one REAL guard run, private state dir, short grace; output APPENDS to $TD/out
    GA_GMG_STATE_DIR="$TD/run" GA_GMG_DOWN_S=0 GA_GMG_SETTLE_S=5 "$GUARD" >> "$TD/out" 2>&1
  }
  mkdir -p "$TD/run"
  wait_state() { wait_for "${GA_DEVT_WAIT_S:-$2}" "[ \"\$(ga_hacli addons info $SLUG --raw-json 2>/dev/null | jq -r '.data.state // empty')\" = '$1' ]"; }

  if [ "$(addon_state)" != started ]; then
    show_verdict "GMGD-20" "destructive cases need a started gm" 1 "gm state: $(addon_state)"
  else
    # 20: toggle repair
    set_watchdog false
    BEFORE=$(addon_wd)
    : > "$TD/out"
    if [ "$BEFORE" = false ]; then tick; else echo "the toggle write did not take (read-back '$BEFORE')" > "$TD/out"; fi
    AFTER=$(addon_wd)
    if grep -q 'turned ON' "$TD/out"; then W=1; else W=0; fi
    if [ "$BEFORE" = false ] && [ "$AFTER" = true ] && [ "$W" = 1 ]; then _rc=0; else _rc=1; fi
    show_verdict "GMGD-20" "toggle off -> one guard tick turns it ON and says so at WARNING" "$_rc" "before=$BEFORE after=$AFTER warning=$W :: $(tr '\n' '|' < "$TD/out" | cut -c1-200)"

    # 21: kill -9 -> the Supervisor watchdog revives it
    CTR=$(ga_ctr_exact "$SLUG" 2>/dev/null)
    docker kill -s KILL "$CTR" >/dev/null 2>&1
    if wait_state started 90; then _rc=0; else _rc=1; fi
    show_verdict "GMGD-21" "kill -9 on gm: back to 'started' within 90 s by the Supervisor watchdog" "$_rc" "container ${CTR:-none}, state now $(addon_state)"

    # 22: deliberate stop
    touch "$MARKER"
    : > "$TD/out"
    ga_hacli addons stop "$SLUG" >/dev/null 2>&1
    tick; sleep 2; tick
    S=$(addon_state)
    if [ "$S" = stopped ] && grep -q 'deliberate-stop marker' "$TD/out"; then _rc=0; else _rc=1; fi
    show_verdict "GMGD-22" "marker + stop: two guard ticks leave gm stopped (state 'stopped', not 'error')" "$_rc" "state=$S :: $(tr '\n' '|' < "$TD/out" | cut -c1-200)"

    # 23: marker gone, still stopped -> the start net
    rm -f "$MARKER"; rm -rf "$TD/run"; mkdir -p "$TD/run"; : > "$TD/out"
    tick; sleep 2; tick
    if wait_state started 60 && [ "$(jq -r '.state // empty' "$SHARE_FILE" 2>/dev/null)" = revived ]; then _rc=0; else _rc=1; fi
    show_verdict "GMGD-23" "no marker, down past the grace: the guard starts gm and publishes state=revived" "$_rc" "state=$(addon_state) json=$(jq -c '{state,detail}' "$SHARE_FILE" 2>/dev/null)"
  fi
fi

suite_end
