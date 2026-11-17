#!/bin/sh
# Host-side selftest of ga_manager_stop/test.sh against a stateful stub of docker/hassio_cli.
# Known-good (clean stop) must PASS; each broken stop (SIGKILL exit 137, state `error`, too
# slow, container gone, old gm version, gm not started) must FAIL on the named check; without
# GA_TEST_DESTRUCTIVE the stop is never issued (must SKIP and leave gm untouched).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/devsuite_selftest.sh"
ds_init
F="$W/f"; mkdir -p "$F"

cat > "$W/bin/docker" <<'STUB'
#!/bin/sh
# $FAKE: state, version, stop_state (what a stop leaves), exit_code ("" = container gone), stop_secs
case "$1" in
  exec)  shift 3
    case "$2" in
      info)  printf '{"result":"ok","data":{"state":"%s","version":"%s"}}\n' "$(cat "$FAKE/state")" "$(cat "$FAKE/version")" ;;
      stop)  echo "stop" >> "$FAKE/calls"; /bin/sleep "$(cat "$FAKE/stop_secs")"; cat "$FAKE/stop_state" > "$FAKE/state" ;;
      start) echo "start" >> "$FAKE/calls"; echo started > "$FAKE/state" ;;
    esac ;;
  inspect) case "$*" in
      *ExitCode*) [ -s "$FAKE/exit_code" ] && cat "$FAKE/exit_code" || exit 1 ;;
      *) echo true ;;
    esac ;;
esac
STUB
chmod +x "$W/bin/docker"

good() { rm -rf "$F"; mkdir -p "$F"; echo started > "$F/state"; echo 0.277.7 > "$F/version"; echo stopped > "$F/stop_state"; echo 0 > "$F/exit_code"; echo 0 > "$F/stop_secs"; : > "$F/calls"; }
run() { ds_run ga_manager_stop FAKE="$F" "$@"; }

echo "== no flag: the stop is never issued"
good; run
ds_expect GMS-01 PASS "gm started, 0.277.7"
ds_expect GMS-02..05 SKIP "no GA_TEST_DESTRUCTIVE"
[ ! -s "$F/calls" ] && { echo "  ok    no stop/start was issued"; DS_PASS=$((DS_PASS + 1)); } || { echo "  FAIL  stop issued without the flag"; DS_FAIL=$((DS_FAIL + 1)); }
good; echo 0.277.6 > "$F/version"; run;   ds_expect GMS-01 FAIL "gm older than the fix"
good; echo stopped > "$F/state"; run;      ds_expect GMS-01 FAIL "gm not started"

echo "== destructive, clean stop"
good; run GA_TEST_DESTRUCTIVE=1
for i in 02 03 04 05; do ds_expect "GMS-$i" PASS "clean stop, ExitCode 0, restarted"; done
echo "== destructive, each broken stop"
good; echo 137 > "$F/exit_code"; run GA_TEST_DESTRUCTIVE=1;  ds_expect GMS-04 FAIL "SIGKILL (137)"
good; echo error > "$F/stop_state"; run GA_TEST_DESTRUCTIVE=1; ds_expect GMS-03 FAIL "Supervisor files the stop as error"
good; echo 2 > "$F/stop_secs"; run GA_TEST_DESTRUCTIVE=1 GA_GMS_STOP_LIMIT_S=1; ds_expect GMS-02 FAIL "stop slower than the limit"
good; : > "$F/exit_code"; run GA_TEST_DESTRUCTIVE=1;         ds_expect GMS-04 FAIL "container gone: unreadable ExitCode is a FAIL, not a pass"
good; run GA_TEST_DESTRUCTIVE=1
[ "$(cat "$F/state")" = started ] && { echo "  ok    gm is started again after the run"; DS_PASS=$((DS_PASS + 1)); } || { echo "  FAIL  gm left $(cat "$F/state")"; DS_FAIL=$((DS_FAIL + 1)); }

ds_done
