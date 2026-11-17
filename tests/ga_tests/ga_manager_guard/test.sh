#!/bin/sh
# ga-manager-guard (Odoo #2166): the LIVE script against a stateful stub of
# `docker exec hassio_cli ha addons ...`. Only docker is stubbed (the seam to
# the Supervisor); every decision runs for real.
#
# must-flag:     gm stopped by a crash -> started; toggle off -> turned on;
#                the Supervisor's 5-attempt give-up (state stays stopped, watchdog
#                on) -> the guard starts it; start keeps failing -> loud ERROR.
# must-NOT-flag: gm running -> no start, no toggle write; deliberate-stop marker
#                -> no start; within the grace period -> no start; not installed
#                -> nothing; Supervisor unreachable -> nothing.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SUT="${GA_GMG_BIN:-$ROOT/buildroot-external/rootfs-overlay/usr/sbin/ga-manager-guard}"
SH="${GA_T_SHELL:-sh}"
W="$(mktemp -d -t gmg-XXXXXX)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/run" "$W/f"
pass=0; fail=0
PASS() { echo "  PASS  $1"; pass=$((pass+1)); }
FAIL() { echo "  FAIL  $1 ($2)"; fail=$((fail+1)); }

[ -s "$SUT" ] || { echo "FAIL: guard script missing: $SUT"; exit 1; }

cat > "$W/bin/docker" <<'STUB'
#!/bin/sh
# docker exec hassio_cli ha addons <info|options|start> <slug> ...
# scenario files in $FAKE: installed, unreachable, state, watchdog (true/false),
# start_ok (a start moves state to started), opt_ok (an options write sticks)
echo "$*" >> "$FAKE/calls"
shift 3   # exec hassio_cli ha
[ -f "$FAKE/unreachable" ] && { echo "Error: Supervisor not reachable" >&2; exit 1; }
[ -f "$FAKE/installed" ] || { echo "Error: Addon $3 does not exist" >&2; exit 1; }
case "$2" in
  info) printf '{"result":"ok","data":{"state":"%s","watchdog":%s}}\n' "$(cat "$FAKE/state")" "$(cat "$FAKE/watchdog")" ;;
  options) if [ -f "$FAKE/opt_ok" ]; then echo true > "$FAKE/watchdog"; else echo "Error: boom" >&2; exit 1; fi ;;
  start) if [ -f "$FAKE/start_ok" ]; then echo started > "$FAKE/state"; else echo "Error: start failed" >&2; exit 1; fi ;;
esac
STUB
chmod +x "$W/bin/docker"

reset() {   # reset <state> <watchdog>
    rm -rf "$W/f" "$W/run" "$W/stop"; mkdir -p "$W/f" "$W/run"
    : > "$W/f/installed"; echo "$1" > "$W/f/state"; echo "$2" > "$W/f/watchdog"
    : > "$W/f/start_ok"; : > "$W/f/opt_ok"; : > "$W/f/calls"
}
tick() {    # tick <uptime-seconds>  -> output in $W/out
    printf '%s 0.00\n' "$1" > "$W/uptime"
    FAKE="$W/f" GA_GMG_DOCKER="$W/bin/docker" GA_GMG_STATE_DIR="$W/run" GA_GMG_UPTIME_FILE="$W/uptime" \
    GA_GMG_STOP_MARKER="$W/stop" GA_GMG_PUBLISH=/nonexistent GA_GMG_SETTLE_S=0 GA_GMG_NOW=1800000000 \
    GA_GMG_DOWN_S=600 GA_GMG_MAX_FAILS=3 $SH "$SUT" > "$W/out" 2>&1
    echo $? > "$W/rc"
}
starts() { grep -c "addons start" "$W/f/calls" 2>/dev/null || true; }
optwrites() { grep -c "addons options" "$W/f/calls" 2>/dev/null || true; }
check() { # check <name> <cmd...>
    _n="$1"; shift
    if "$@"; then PASS "$_n"; else FAIL "$_n" "$(tr '\n' '|' < "$W/out" | cut -c1-300)"; fi
}
has() { grep -q "$1" "$W/out"; }
state_is() { [ "$(cat "$W/f/state")" = "$1" ]; }
eq() { [ "$1" = "$2" ]; }

echo ""; echo "=== ga-manager-guard ($SH) ==="

# --- must-flag ---------------------------------------------------------------
reset error true            # crash / 143: stopped with state error
tick 1000; check "GMG-01 first sight of a down gm only starts the clock" eq "$(starts)" 0
tick 1700; check "GMG-02 down 700 s (crash): the guard starts it" state_is started
check "GMG-02b ... and says so at WARNING" has '<4>ga-manager-guard: .*started by the guard'

reset started false         # toggle off, gm running fine
tick 1000; check "GMG-03 toggle off: turned on" eq "$(cat "$W/f/watchdog")" true
check "GMG-03b ... at WARNING" has '<4>ga-manager-guard: .*turned ON'
check "GMG-03c ... without touching a running gm" eq "$(starts)" 0

reset stopped true          # the Supervisor gave up after 5 restarts: watchdog on, still stopped
tick 1000; tick 1650; check "GMG-04 5-attempt give-up (watchdog on, stopped 650 s): started" state_is started

reset stopped false         # both gaps at once
tick 1000; tick 1700
check "GMG-05 toggle off AND down: both fixed" sh -c "[ \"\$(cat '$W/f/watchdog')\" = true ] && [ \"\$(cat '$W/f/state')\" = started ]"

reset stopped true; rm -f "$W/f/start_ok"
tick 1000; tick 1700; check "GMG-06 start fails once: warning, no ERROR yet" has 'start attempt 1/3 failed'
tick 1820; tick 1940
check "GMG-07 3 failed starts: loud ERROR (<3>)" has '<3>ga-manager-guard: ERROR: .*will NOT start: 3 consecutive'
: > "$W/f/start_ok"; tick 2060
check "GMG-08 recovers on the next tick once start works" state_is started

reset started false; rm -f "$W/f/opt_ok"
tick 1000; check "GMG-09 toggle cannot be set: ERROR (<3>), not silent" has '<3>ga-manager-guard: ERROR: .*could NOT be turned on'

# --- must-NOT-flag -----------------------------------------------------------
reset started true
tick 1000; tick 5000
check "GMG-10 running gm + toggle on: no start" eq "$(starts)" 0
check "GMG-10b ... no options write" eq "$(optwrites)" 0
check "GMG-10c ... no WARNING/ERROR line" sh -c "! grep -qE '<[34]>' '$W/out'"

reset stopped true
# GA_GMG_NOW is 1800000000: make the marker look 1 h old
touch "$W/stop"; touch -d @$((1800000000 - 3600)) "$W/stop"
tick 1000
check "GMG-11c marker named at WARNING (once)" has '<4>ga-manager-guard: .*deliberate-stop marker'
tick 5000
check "GMG-11 deliberate-stop marker: not started" state_is stopped
check "GMG-11b ... no start call" eq "$(starts)" 0

touch -d @$((1800000000 - 200000)) "$W/stop"    # expired (> 24 h)
tick 5100; tick 5800
check "GMG-12 expired marker (55 h) is ignored: started" state_is started
check "GMG-12b ... and logged as expired" has 'expired, ignored'

reset stopped true
tick 1000; tick 1300
check "GMG-13 down 300 s < 600 s grace: not started (Supervisor watchdog goes first)" state_is stopped

reset stopped true; rm -f "$W/f/installed"
tick 1000; tick 9000
check "GMG-14 not installed (fresh flash): no-op, no WARNING/ERROR" sh -c "[ \"\$(cat '$W/rc')\" = 0 ] && ! grep -qE '<[34]>' '$W/out'"

reset stopped true; : > "$W/f/unreachable"
tick 1000; tick 9000
check "GMG-15 Supervisor unreachable: no-op, rc 0, no start" sh -c "[ \"\$(cat '$W/rc')\" = 0 ] && [ \"\$(grep -c 'addons start' '$W/f/calls')\" = 0 ]"

reset stopped true
tick 1000; echo started > "$W/f/state"; tick 1100; tick 5000
check "GMG-16 down, then back by itself: clock reset, no start" eq "$(starts)" 0
echo stopped > "$W/f/state"; tick 5100; tick 5300
check "GMG-16b ... a NEW outage gets a fresh grace period" state_is stopped

echo ""; echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
