#!/bin/sh
# Self-test for lib/app_ready.sh and its wiring in run_all.sh. Host-side, no device.
#   sh tests/ga_tests/lib/app_ready_selftest.sh
# Drives the LIVE functions through the GA_APP_* seams with scripted answers:
#   must PASS  apps that start answering after a delay (the shape this fixes)
#   must FAIL  an app that never answers within the bound; a bound that is honoured
#   must PASS  nothing to wait for (no containers) - and must not block
# plus the wiring: run_all.sh sources the helper, calls it before the suites and
# aborts on failure. Red proof: the helper's wait loop removed makes cases 1 and 2 fail.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/app_ready.sh" ] || { echo "FAIL: $HERE/app_ready.sh not found"; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
. "$HERE/app_ready.sh"
n=0; bad=0
check() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got [$3] want [$2])"; bad=$((bad+1)); fi; }

PS_ALL="printf 'homeassistant\naddon_abc_ga_influxdbv1\naddon_abc_ga_manager\n'"
# counter-file backed command: answers 000 for the first N calls, then the real code
slow() { # <name> <fails> <code>
  echo 0 > "$WORK/$1"
  echo "c=\$(cat $WORK/$1); echo \$((c+1)) > $WORK/$1; if [ \$c -lt $2 ]; then echo 000; else echo $3; fi"
}
export GA_PREFLIGHT_INTERVAL=1 GA_PREFLIGHT_TIMEOUT=10
export GA_APP_PS_CMD="$PS_ALL"

# 1. container Up but apps answer only after a delay -> wait, then pass
GA_APP_CORE_CMD=$(slow core1 2 401); GA_APP_INFLUX_CMD=$(slow inf1 1 204); export GA_APP_CORE_CMD GA_APP_INFLUX_CMD
out=$(ga_wait_apps_ready); rc=$?
check "late-starting apps: rc 0" 0 "$rc"
check "late-starting apps: core was polled until it answered" 3 "$(cat $WORK/core1)"
check "late-starting apps: said which apps" 1 "$(echo "$out" | grep -c 'answering \[core influx\]')"

# 2. one app never answers -> bounded, rc 1, names it
GA_PREFLIGHT_TIMEOUT=3
GA_APP_CORE_CMD="echo 401"; GA_APP_INFLUX_CMD="echo 000"; export GA_APP_CORE_CMD GA_APP_INFLUX_CMD
t0=$(date +%s); out=$(ga_wait_apps_ready); rc=$?; el=$(( $(date +%s) - t0 ))
check "dead influx: rc 1" 1 "$rc"
check "dead influx: names influx only" 1 "$(echo "$out" | grep -c 'not answering after 3 s: influx$')"
[ "$el" -le 8 ] && b=bounded || b="unbounded(${el}s)"; check "dead influx: bounded by the timeout" bounded "$b"

# 3. a 5xx from Core is not an answer
GA_APP_CORE_CMD="echo 503"; GA_APP_INFLUX_CMD="echo 204"; export GA_APP_CORE_CMD GA_APP_INFLUX_CMD
out=$(ga_wait_apps_ready); rc=$?
check "Core 503 is not an answer: rc 1" 1 "$rc"

# 4. only present containers are waited for
GA_APP_PS_CMD="printf 'homeassistant\n'"; GA_APP_CORE_CMD="echo 401"; GA_APP_INFLUX_CMD="echo 000"; export GA_APP_PS_CMD GA_APP_CORE_CMD GA_APP_INFLUX_CMD
out=$(ga_wait_apps_ready); rc=$?
check "no influx container: not waited for, rc 0" 0 "$rc"
GA_APP_PS_CMD="printf 'something_else\n'"; export GA_APP_PS_CMD
out=$(ga_wait_apps_ready); rc=$?
check "no relevant container: rc 0 and says so" "0 1" "$rc $(echo "$out" | grep -c 'nothing to wait for')"

# 5. wiring in the runner
RUN="$HERE/../run_all.sh"
check "run_all.sh sources lib/app_ready.sh" 1 "$(grep -c '^\. "\$SCRIPT_DIR/lib/app_ready.sh"' "$RUN")"
check "run_all.sh calls ga_wait_apps_ready" 1 "$(grep -c 'ga_wait_apps_ready' "$RUN" | sed 's/^[2-9]/1/')"
a=$(grep -n 'ga_wait_apps_ready' "$RUN" | head -1 | cut -d: -f1); b=$(grep -n '^for suite in \$SUITES' "$RUN" | head -1 | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && o=before || o=wrong
check "preflight runs before the suites" before "$o"
check "preflight failure aborts the run" 1 "$(grep -A1 'PREFLIGHT FAILED' "$RUN" | grep -c 'exit 3')"

# the serial-console runner ships lib files one by one: the helper must be among them
check "serial path ships lib/app_ready.sh" 1 "$(grep -c 'lib/app_ready.sh -O' "$HERE/../../run_device_tests.sh")"

[ "$n" -ge 12 ] || { echo "FAIL: only $n checks ran"; exit 1; }
echo "$((n-bad))/$n passed"
[ "$bad" -eq 0 ]
