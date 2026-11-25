#!/bin/sh
# Host-side selftest of ga_manager_guard_device/test.sh: the LIVE suite, and for the
# destructive half the LIVE /usr/sbin/ga-manager-guard, against a stateful stub of
# docker / hassio_cli / systemctl / journalctl. Known-good state (must PASS), each broken
# state (must FAIL on the named check), and the destructive gate (must SKIP without the flag).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/devsuite_selftest.sh"
ds_init
GUARD="$DS_ROOT/../buildroot-external/rootfs-overlay/usr/sbin/ga-manager-guard"
[ -s "$GUARD" ] || { echo "FATAL: guard script missing: $GUARD"; exit 2; }
F="$W/f"; mkdir -p "$F"

# --- stubs --------------------------------------------------------------------
cat > "$W/bin/docker" <<'STUB'
#!/bin/sh
# state files in $FAKE: state, watchdog (true/false), has_flag (yes/no), kill_revives (yes/no)
case "$1" in
  exec)
    if [ "$3" = sh ]; then   # the Supervisor API write: POST /addons/<slug>/options {"watchdog":<v>}
      v=$(printf '%s' "$5" | sed -n 's/.*watchdog\\":\(true\|false\)}.*/\1/p')
      [ -n "$v" ] && [ -f "$FAKE/write_ok" ] && echo "$v" > "$FAKE/watchdog"   # write_ok absent = the write silently does nothing
      exit 0
    fi
    shift 3          # exec hassio_cli ha
    [ "$1" = addons ] || exit 1
    case "$2" in
      info)    if [ -f "$FAKE/no_wd_field" ]; then printf '{"result":"ok","data":{"state":"%s","version":"0.277.7"}}\n' "$(cat "$FAKE/state")"
               else printf '{"result":"ok","data":{"state":"%s","watchdog":%s,"version":"0.277.7"}}\n' "$(cat "$FAKE/state")" "$(cat "$FAKE/watchdog")"; fi ;;
      options) if [ "$3" = "--help" ]; then [ "$(cat "$FAKE/has_flag")" = yes ] && echo "Flags: --watchdog  watchdog toggle" || echo "Flags: --boot"
               else [ "$(cat "$FAKE/has_flag")" = yes ] && echo "$5" > "$FAKE/watchdog" || exit 1; fi ;;
      start)   echo started > "$FAKE/state" ;;
      stop)    echo stopped > "$FAKE/state" ;;
    esac ;;
  inspect) case "$*" in *hassio_cli*) echo "ghcr.io/greenautarky/aarch64-hassio-cli:2026.10.1" ;; *) echo true ;; esac ;;
  ps)    echo app_99f1cad4_ga_manager ;;
  kill)  [ "$(cat "$FAKE/kill_revives")" = yes ] && echo started > "$FAKE/state" || echo stopped > "$FAKE/state" ;;
esac
STUB
cat > "$W/bin/systemctl" <<'STUB'
#!/bin/sh
case "$*" in
  "is-active ga-manager-guard.timer") cat "$FAKE/timer_active" ;;
  *NextElapseUSecMonotonic*) cat "$FAKE/next" ;;
  *ExecMainExitTimestampMonotonic*) cat "$FAKE/last_run_us" ;;
  *"-p Result -p ExecMainStatus"*) printf 'Result=%s\nExecMainStatus=%s\n' "$(cat "$FAKE/result")" "$(cat "$FAKE/mainstatus")" ;;
esac
STUB
cat > "$W/bin/journalctl" <<'STUB'
#!/bin/sh
cat "$FAKE/jerr" 2>/dev/null
STUB
cat > "$W/bin/sleep" <<'STUB'
#!/bin/sh
# the clock: advance the fake uptime the guard reads
u=$(cut -d' ' -f1 "$FAKE_UPTIME"); echo "$((u + ${1%%.*})) 0.00" > "$FAKE_UPTIME"
STUB
cat > "$W/bin/publish" <<'STUB'
#!/bin/sh
cat > "$1"
STUB
chmod +x "$W/bin/"*

good() {   # reset to the known-good device
  rm -rf "$F"; mkdir -p "$F"
  echo started > "$F/state"; echo true > "$F/watchdog"; echo yes > "$F/has_flag"; : > "$F/write_ok"; echo yes > "$F/kill_revives"
  echo active > "$F/timer_active"; echo 90000000 > "$F/next"; echo 940000000 > "$F/last_run_us"
  echo success > "$F/result"; echo 0 > "$F/mainstatus"; : > "$F/jerr"
  echo "1000 0.00" > "$W/uptime"; rm -f "$W/share.json" "$W/marker"
}
run() {   # run [extra VAR=val ...]
  ds_run ga_manager_guard_device FAKE="$F" FAKE_UPTIME="$W/uptime" GA_GMGD_UPTIME_FILE="$W/uptime" \
    GA_GMGD_SHARE_FILE="$W/share.json" GA_GMGD_MARKER="$W/marker" GA_GMGD_BIN="$GUARD" \
    GA_GMG_UPTIME_FILE="$W/uptime" GA_GMG_SHARE_FILE="$W/share.json" GA_GMG_PUBLISH="$W/bin/publish" \
    GA_GMG_STOP_MARKER="$W/marker" "$@"
}

echo "== known-good, no flag: non-destructive half green, destructive SKIPPED"
good; run
for i in 01 02 03 04 05 06 07 08 09; do ds_expect "GMGD-$i" PASS "healthy device"; done
ds_expect "GMGD-20..23" SKIP "no GA_TEST_DESTRUCTIVE"

echo "== must-flag: each broken device state"
good; echo inactive > "$F/timer_active"; run;                          ds_expect GMGD-02 FAIL "timer not active"
good; echo 0 > "$F/last_run_us"; run GA_DEVT_WAIT_S=1;                  ds_expect GMGD-04 FAIL "guard never ran"
good; echo 100000000 > "$F/last_run_us"; run;                           ds_expect GMGD-04 FAIL "last run 900 s ago"
# long uptime: the timestamp exceeds 2^31 us (32-bit shells wrapped here after ~36 min)
good; echo "7000 0.00" > "$W/uptime"; echo 6900000000 > "$F/last_run_us"; run;  ds_expect GMGD-04 PASS "uptime 7000 s, last run 100 s ago (> 2^32 us)"
good; echo "7000 0.00" > "$W/uptime"; echo 2147483649 > "$F/last_run_us"; run;  ds_expect GMGD-04 FAIL "uptime 7000 s, last run 6850 s ago: stopped timer"
good; echo "70000 0.00" > "$W/uptime"; echo 123456 > "$F/last_run_us"; run;      ds_expect GMGD-04 FAIL "timestamp shorter than 7 digits is 0 s: stale"
good; echo 1 > "$F/mainstatus"; run;                                    ds_expect GMGD-05 FAIL "last run rc 1"
good; echo false > "$F/watchdog"; run;                                  ds_expect GMGD-07 FAIL "toggle off"
good; : > "$F/no_wd_field"; run;                                        ds_expect GMGD-08 FAIL "ha addons info does not expose .data.watchdog"
good; echo false > "$F/watchdog"; run;                                  ds_expect GMGD-08 FAIL "watchdog exposed but false"
good; echo "<3>ga-manager-guard: ERROR: x" > "$F/jerr"; run;            ds_expect GMGD-09 FAIL "guard ERROR in the journal"
good; printf '{"state":"start_failing","ts":1}\n' > "$W/share.json"; echo stopped > "$F/state"; run
ds_expect GMGD-06 FAIL "start_failing while gm is down: the fault is still true"
good; printf '{"state":"start_failing","ts":1}\n' > "$W/share.json"; run
ds_expect GMGD-06 PASS "start_failing record but gm is up again: stale, not a finding"
good; printf '{"state":"revived","ts":1}\n' > "$W/share.json"; run;     ds_expect GMGD-06 PASS "an event record"
good; printf 'not json' > "$W/share.json"; run;                         ds_expect GMGD-06 FAIL "garbage status file"

echo "== destructive half (the LIVE guard against the stateful stub)"
good; run GA_TEST_DESTRUCTIVE=1
for i in 20 21 22 23; do ds_expect "GMGD-$i" PASS "destructive cases, healthy supervisor"; done
[ -e "$W/marker" ] && { echo "  FAIL  marker left behind"; DS_FAIL=$((DS_FAIL + 1)); } || { echo "  ok    marker removed by the trap"; DS_PASS=$((DS_PASS + 1)); }
ds_expect GMGD-23 PASS "state=revived published"
good; echo no > "$F/kill_revives"; run GA_TEST_DESTRUCTIVE=1 GA_DEVT_WAIT_S=2;           ds_expect GMGD-21 FAIL "the Supervisor does not revive a killed gm"
[ "$(cat "$F/state")" = started ] && { echo "  ok    trap restored gm to started after a red run"; DS_PASS=$((DS_PASS + 1)); } || { echo "  FAIL  gm left $(cat "$F/state")"; DS_FAIL=$((DS_FAIL + 1)); }
good; rm -f "$F/write_ok"; run GA_TEST_DESTRUCTIVE=1;                   ds_expect GMGD-20 FAIL "the toggle write silently does nothing: read-back still true"

echo "== mutant guard (does nothing): the destructive cases that depend on it go red"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/noop-guard"; chmod +x "$W/bin/noop-guard"
good; run GA_TEST_DESTRUCTIVE=1 GA_GMGD_BIN="$W/bin/noop-guard" GA_DEVT_WAIT_S=2
ds_expect GMGD-20 FAIL "guard that never turns the toggle on"
ds_expect GMGD-23 FAIL "guard that never starts gm"

ds_done
