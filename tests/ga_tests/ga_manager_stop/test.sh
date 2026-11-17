#!/bin/sh
# ga_manager_stop - ga_manager stops CLEANLY (Odoo #2165, gm 0.277.7+) ON the device.
#
# Before 0.277.7 a `ha addons stop` ended the add-on with SIGKILL after Docker's 10 s
# grace (ExitCode 137) and the Supervisor filed the state as `error`, which is what a
# crash looks like - and the watchdog/guard act on crashes. The fix makes gm exit 0 on
# SIGTERM inside the grace period.
#
#   GMS-01  gm is installed, `started`, and at least 0.277.7 (the fix)
#   GMS-02  (destructive) `ha addons stop` returns within 10 s
#   GMS-03  (destructive) ...the state is `stopped` (not `error`)
#   GMS-04  (destructive) ...and the container ExitCode is 0 (not 137 = SIGKILL)
#   GMS-05  (destructive) ...and `ha addons start` brings it back to `started`
#
# Destructive = GA_TEST_DESTRUCTIVE=1: gm is down for ~20-60 s (no fm contact, no alarms
# in that window). A trap starts it again whatever happens. Canary only; never during a
# soak.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "ga_manager clean stop (Odoo #2165)"

SLUG="${GA_GMS_SLUG:-99f1cad4_ga_manager}"
MIN_VERSION="${GA_GMS_MIN_VERSION:-0.277.7}"
STOP_LIMIT_S="${GA_GMS_STOP_LIMIT_S:-10}"

addon_json() { ga_hacli addons info "$SLUG" --raw-json 2>/dev/null; }
addon_state() { addon_json | jq -r '.data.state // empty' 2>/dev/null; }
addon_ver()   { addon_json | jq -r '.data.version // empty' 2>/dev/null; }

STATE=$(addon_state); VER=$(addon_ver)
if [ "$STATE" = started ] && ga_ver_ge "$VER" "$MIN_VERSION"; then _rc=0; else _rc=1; fi
show_verdict "GMS-01" "gm is started and >= $MIN_VERSION (the clean-stop fix)" "$_rc" "state=$STATE version=${VER:-unknown}"

if ga_destructive "GMS-02..05" "ha addons stop: stopped, ExitCode 0, within ${STOP_LIMIT_S}s, then start"; then
  if [ "$STATE" != started ]; then
    show_verdict "GMS-02" "stop test needs a started gm" 1 "state=$STATE"
  else
    CTR=$(ga_ctr_exact "$SLUG" 2>/dev/null)
    restore() { [ "$(addon_state)" = started ] || ga_hacli addons start "$SLUG" >/dev/null 2>&1; }
    trap restore EXIT INT TERM
    T0=$(date +%s)
    ga_hacli addons stop "$SLUG" >/dev/null 2>&1
    T1=$(date +%s)
    ELAPSED=$((T1 - T0))
    if [ "$ELAPSED" -le "$STOP_LIMIT_S" ]; then _rc=0; else _rc=1; fi
    show_verdict "GMS-02" "'ha addons stop' returned within ${STOP_LIMIT_S}s (no SIGKILL after Docker's grace)" "$_rc" "took ${ELAPSED}s"

    S=$(addon_state)
    if [ "$S" = stopped ]; then _rc=0; else _rc=1; fi
    show_verdict "GMS-03" "state after the stop is 'stopped' (not 'error')" "$_rc" "state=$S"

    # The container of an add-on stays after a stop (Supervisor removes it only on
    # uninstall/update); an unreadable ExitCode is a FAIL, never a pass.
    EC=$(docker inspect -f '{{.State.ExitCode}}' "$CTR" 2>/dev/null)
    if [ "$EC" = 0 ]; then _rc=0; else _rc=1; fi
    show_verdict "GMS-04" "container ExitCode is 0 (137 would be SIGKILL)" "$_rc" "container=${CTR:-unknown} ExitCode='${EC:-unreadable}'"

    ga_hacli addons start "$SLUG" >/dev/null 2>&1
    if wait_for 120 "[ \"\$(ga_hacli addons info $SLUG --raw-json 2>/dev/null | jq -r '.data.state // empty')\" = started ]"; then _rc=0; else _rc=1; fi
    show_verdict "GMS-05" "'ha addons start' brings gm back to 'started'" "$_rc" "state=$(addon_state)"
  fi
fi

suite_end
