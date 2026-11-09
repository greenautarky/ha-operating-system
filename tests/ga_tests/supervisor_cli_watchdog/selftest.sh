#!/bin/sh
# ga-supervisor-cli-watchdog — the LIVE script against a fake docker / systemctl
# (Odoo #1706). No device. Shell under test: GA_T_SHELL (default sh).
#
# Fixture families (working-method rule 51):
#   MUST-ACT      persistent cli-install failure (supervisor up >= N s monotonic,
#                 no hassio_cli, install-retry signature in the log) -> exactly
#                 ONE supervisor restart, then ga-addon-prime (re)started exactly
#                 once (by the watchdog, or by systemd via Requires=).
#   CLOCKS        a wall-clock step forward must not open the age gate, one
#                 backward must not close it; the log window is a line count.
#   FAIL CLOSED   marker not writable -> no restart.
#   ONE ERROR     "cli missing, no signature" is ERROR once per boot, then WARNING.
#   PIN           the log signature == the pinned Supervisor source line.
#   MUST-NOT-ACT  healthy (cli running); first boot still young (< N); cli
#                 missing WITHOUT the signature; supervisor container not
#                 running; Core stopped on purpose (cli running, no Core);
#                 already restarted in this boot (many ticks, still one).
#   PER BOOT      a second boot (new boot id) may fire once again.
#   REPORT        the restart is logged at ERROR (<3>), status JSON published,
#                 a failed restart is not retried.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
suite_start "ga-supervisor-cli-watchdog (live script, fake docker/systemctl)"

ROOT="$SCRIPT_DIR/../../.."
SUT="${GA_SCW_BIN:-$ROOT/buildroot-external/rootfs-overlay/usr/sbin/ga-supervisor-cli-watchdog}"
SH="${GA_T_SHELL:-sh}"
run_test "SCW-00" "the watchdog script exists" "test -s '$SUT'"

W="$(mktemp -d "${TMPDIR:-/tmp}/scw.XXXXXX")"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/run" "$W/share"
NOW0=1800000000          # fixed clock; StartedAt is derived from it

cat > "$W/bin/docker" <<'STUB'
#!/bin/sh
# scenario files in $FAKE: sup_age_s (monotonic seconds the supervisor has run,
# absent = not running), wall_skew_s (wall-clock step since container start: the
# wall-clock StartedAt says age+skew), cli (hassio_cli running), logfile,
# since_empty (a wall-clock window finds nothing: the clock jumped)
case "$1" in
  inspect)
    case "$*" in
      *hassio_supervisor*)
        [ -f "$FAKE/sup_age_s" ] || { echo "false 0001-01-01T00:00:00Z"; exit 0; }
        s=$(cat "$FAKE/sup_age_s"); k=$(cat "$FAKE/wall_skew_s" 2>/dev/null || echo 0)
        case "$*" in
          *State.Running*State.StartedAt*) echo "true $(date -u -d "@$((NOW0 - s - k))" '+%Y-%m-%dT%H:%M:%S').123456789Z" ;;
          *) echo true ;;
        esac ;;
      *hassio_cli*)
        if [ -f "$FAKE/cli" ]; then echo true; else echo "Error: No such object" >&2; exit 1; fi ;;
    esac ;;
  logs)
    case "$*" in
      *--since*) [ -f "$FAKE/since_empty" ] && exit 0; cat "$FAKE/logfile" 2>/dev/null ;;
      *--tail*) n="$3"; tail -n "$n" "$FAKE/logfile" 2>/dev/null ;;
      *) cat "$FAKE/logfile" 2>/dev/null ;;
    esac ;;
esac
STUB
cat > "$W/bin/systemctl" <<'STUB'
#!/bin/sh
case "$1" in
  show) [ -f "$FAKE/no_mono" ] || echo "${MONO_US:-47000000}"; exit 0 ;;
  is-active) cat "$FAKE/prime_state" 2>/dev/null || echo inactive; exit 0 ;;
esac
echo "$*" >> "$FAKE/systemctl.calls"
case "$*" in *ga-addon-prime*) [ -f "$FAKE/prime_restart_fails" ] && exit 1; exit 0 ;; esac
[ -f "$FAKE/restart_fails" ] && exit 1
exit 0
STUB
cat > "$W/bin/publish" <<'STUB'
#!/bin/sh
cat > "$1.tmp" && mv "$1.tmp" "$1"
STUB
chmod +x "$W/bin/"*

SIG='WARNING (MainThread) [supervisor.plugins.base] Error on installing cli plugin, retrying in 30sec'
NOSIG='INFO (MainThread) [supervisor.plugins.cli] Starting CLI plugin'

# scen <name> <sup_age_s|none> <cli yes|no> <log signature|plain|none> [wall_skew_s]
# The fake uptime is age + 47 s (the supervisor unit became active at +47 s).
scen() {
  FAKE="$W/$1"; rm -rf "$FAKE"; mkdir -p "$FAKE"; export FAKE
  [ "$2" = none ] || { echo "$2" > "$FAKE/sup_age_s"; echo "$(( $2 + 47 )).50 1.00" > "$FAKE/uptime"; }
  [ "$2" = none ] && echo "50.00 1.00" > "$FAKE/uptime"
  [ -n "${5:-}" ] && echo "$5" > "$FAKE/wall_skew_s"
  [ "$3" = yes ] && : > "$FAKE/cli"
  case "$4" in
    signature) printf '%s\n%s\n' "$SIG" "$SIG" > "$FAKE/logfile" ;;
    plain) echo "$NOSIG" > "$FAKE/logfile" ;;
  esac
  return 0
}
# tick <boot-id>: one timer tick. Output to $FAKE/out; restarts counted from systemctl calls.
tick() {
  printf '%s\n' "$1" > "$W/bootid"
  PATH="$W/bin:$PATH" NOW0="$NOW0" FAKE="$FAKE" \
  GA_SCW_NOW="$NOW0" GA_SCW_STATE_DIR="${STATE_OVERRIDE:-$W/run}" GA_SCW_BOOTID="$W/bootid" \
  GA_SCW_UPTIME_FILE="$FAKE/uptime" GA_SCW_SETTLE=0 GA_SCW_PRIME_MARKER="$W/prime-marker" \
  GA_SCW_PUBLISH="$W/bin/publish" GA_SCW_SHARE_FILE="$W/share/ga-supervisor-cli-watchdog.json" \
  GA_SCW_DOCKER="$W/bin/docker" GA_SCW_SYSTEMCTL="$W/bin/systemctl" \
  $SH "$SUT" >> "$FAKE/out" 2>&1
}
reset_boot() { rm -f "$W/run/"ga-supervisor-cli-watchdog.* "$W/share/"* "$W/prime-marker"; }
BOOT1=11111111-1111-1111-1111-111111111111
BOOT2=22222222-2222-2222-2222-222222222222

SUPRESTARTS() { grep -c '^restart hassos-supervisor.service$' "$W/$1/systemctl.calls" 2>/dev/null; }
PRIMERESTARTS() { grep -c '^restart --no-block ga-addon-prime.service$' "$W/$1/systemctl.calls" 2>/dev/null; }

# --- MUST-ACT: persistent cli-install failure -> exactly one restart, across many ticks
reset_boot; scen deadlock 300 no signature
tick $BOOT1; tick $BOOT1; tick $BOOT1; tick $BOOT1
run_test "SCW-10" "failure: exactly ONE supervisor restart over four ticks" "[ \"\$(SUPRESTARTS deadlock)\" = 1 ]"
run_test "SCW-11" "the restart is logged at ERROR (<3>), names the persistent cli-install failure and #1706" "grep -q '^<3>.*persistent cli-plugin install failure.*restarting hassos-supervisor.service ONCE.*#1706' '$W/deadlock/out'"
run_test "SCW-12" "status JSON published with state restarted + valid schema" "grep -q '\"state\":\"restarted\"' '$W/share/ga-supervisor-cli-watchdog.json' && grep -q '\"schema_version\":1' '$W/share/ga-supervisor-cli-watchdog.json'"
run_test "SCW-13" "already restarted this boot: ticks 2-4 stayed silent (one ERROR line only)" "[ \"\$(grep -c '^<3>' '$W/deadlock/out')\" = 1 ]"
run_test "SCW-14" "the age gate is 150 s: a supervisor up 160 s acts, one up 140 s does not" "reset_boot; scen g160 160 no signature; tick $BOOT1; reset_boot; scen g140 140 no signature; tick $BOOT1; [ \"\$(SUPRESTARTS g160)\" = 1 ] && [ ! -f '$W/g140/systemctl.calls' ]"

# --- ga-addon-prime after the restart: (re)started exactly once
# prime failed/inactive: systemd does not restart a failed unit via Requires= -> the watchdog does, once
reset_boot; scen prime_failed 300 no signature; echo failed > "$W/prime_failed/prime_state"
tick $BOOT1; tick $BOOT1; tick $BOOT1
run_test "SCW-15" "prime failed (gave up before the cli existed): restarted exactly ONCE after the supervisor restart, not on later ticks" "[ \"\$(PRIMERESTARTS prime_failed)\" = 1 ] && grep -n '' '$W/prime_failed/systemctl.calls' | head -1 | grep -q 'restart hassos-supervisor.service'"
# prime activating/active: systemd already restarted it via Requires= (or it is done) -> no second restart
reset_boot; scen prime_act 300 no signature; echo activating > "$W/prime_act/prime_state"; tick $BOOT1; tick $BOOT1
run_test "SCW-16" "prime activating (restarted by systemd via Requires=): the watchdog adds no second restart" "[ \"\$(PRIMERESTARTS prime_act)\" = 0 ] && [ \"\$(SUPRESTARTS prime_act)\" = 1 ]"
reset_boot; scen prime_ok 300 no signature; echo active > "$W/prime_ok/prime_state"; tick $BOOT1
run_test "SCW-17" "prime active (succeeded this boot): left alone" "[ \"\$(PRIMERESTARTS prime_ok)\" = 0 ]"
reset_boot; scen prime_done 300 no signature; : > "$W/prime-marker"; tick $BOOT1
run_test "SCW-18" "prime done-marker present: prime not restarted" "[ \"\$(PRIMERESTARTS prime_done)\" = 0 ]"
reset_boot; scen prime_nosup 300 no signature; echo failed > "$W/prime_nosup/prime_state"; : > "$W/prime_nosup/restart_fails"; tick $BOOT1
run_test "SCW-19" "supervisor restart failed: prime is NOT touched" "[ \"\$(PRIMERESTARTS prime_nosup)\" = 0 ]"

# --- PER BOOT: the second boot may fire once again
scen deadlock2 300 no signature
tick $BOOT2; tick $BOOT2
run_test "SCW-20" "second boot (new boot id): fires once again, once" "[ \"\$(SUPRESTARTS deadlock2)\" = 1 ]"

# --- CLOCKS (fix 2): the age is monotonic, the log window a line count
reset_boot; scen jumpfwd 100 no signature 3600; tick $BOOT1
run_test "SCW-21" "wall clock jumped FORWARD +1 h (wall StartedAt says 3700 s old, monotonic age 100 s < 150): no restart" "[ ! -f '$W/jumpfwd/systemctl.calls' ]"
reset_boot; scen jumpback 300 no signature -3600; : > "$W/jumpback/since_empty"; tick $BOOT1
run_test "SCW-22" "wall clock jumped BACKWARD -1 h (wall StartedAt in the future, monotonic age 300 s, log window by wall time finds nothing): still ONE restart" "[ \"\$(SUPRESTARTS jumpback)\" = 1 ]"
reset_boot; scen nomono 300 no signature; : > "$W/nomono/no_mono"; tick $BOOT1
run_test "SCW-23" "systemd cannot give the monotonic stamp: falls back to uptime (347 s), acts" "[ \"\$(SUPRESTARTS nomono)\" = 1 ]"
reset_boot; scen nomono_young 60 no signature; : > "$W/nomono_young/no_mono"; tick $BOOT1
run_test "SCW-24" "... and uptime 107 s < 150: no restart" "[ ! -f '$W/nomono_young/systemctl.calls' ]"
reset_boot; scen tail 300 no plain; { printf '%s\n' "$SIG"; i=0; while [ $i -lt 100 ]; do echo "INFO filler $i"; i=$((i+1)); done; } > "$W/tail/logfile"; tick $BOOT1
run_test "SCW-25" "signature inside the last 500 log lines (100 filler lines after it): found, one restart" "[ \"\$(SUPRESTARTS tail)\" = 1 ]"

# --- MUST-NOT-ACT
reset_boot; scen healthy 600 yes plain; tick $BOOT1; tick $BOOT1
run_test "SCW-30" "healthy (hassio_cli running): no restart" "[ ! -f '$W/healthy/systemctl.calls' ]"
run_test "SCW-31" "healthy: status ok published" "grep -q '\"state\":\"ok\"' '$W/share/ga-supervisor-cli-watchdog.json'"

reset_boot; scen young 90 no signature; tick $BOOT1
run_test "SCW-32" "normal first boot (supervisor up 90 s < N, cli not there yet, retries logged): no restart" "[ ! -f '$W/young/systemctl.calls' ]"

reset_boot; scen nosig 600 no plain; tick $BOOT1
run_test "SCW-33" "cli missing WITHOUT the signature: no restart" "[ ! -f '$W/nosig/systemctl.calls' ]"
run_test "SCW-34" "... and said so at ERROR with state cli_missing_no_signature" "grep -q '^<3>.*NOT restarting' '$W/nosig/out' && grep -q 'cli_missing_no_signature' '$W/share/ga-supervisor-cli-watchdog.json'"
tick $BOOT1; tick $BOOT1
run_test "SCW-38" "no-signature: ONE ERROR per boot, later ticks are WARNING (<4>)" "[ \"\$(grep -c '^<3>' '$W/nosig/out')\" = 1 ] && [ \"\$(grep -c '^<4>.*NOT restarting' '$W/nosig/out')\" = 2 ]"
tick $BOOT2
run_test "SCW-39" "no-signature: a new boot logs its ERROR again" "[ \"\$(grep -c '^<3>' '$W/nosig/out')\" = 2 ]"

reset_boot; scen supdown none no signature; tick $BOOT1
run_test "SCW-35" "supervisor container not running: no restart" "[ ! -f '$W/supdown/systemctl.calls' ]"

reset_boot; scen coreoff 900 yes plain; tick $BOOT1
run_test "SCW-36" "Core intentionally stopped (cli up, no Core): no restart, Core is not part of the condition" "[ ! -f '$W/coreoff/systemctl.calls' ]"

reset_boot; scen healed 900 yes signature; tick $BOOT1
run_test "SCW-37" "cli running although the log still holds old install retries: no restart" "[ ! -f '$W/healed/systemctl.calls' ]"

# --- a failing restart is not retried
reset_boot; scen failing 300 no signature; : > "$W/failing/restart_fails"
tick $BOOT1; tick $BOOT1; tick $BOOT1
run_test "SCW-40" "restart fails: attempted once, never retried this boot" "[ \"\$(SUPRESTARTS failing)\" = 1 ]"
run_test "SCW-41" "restart failure logged at ERROR, state restart_failed" "grep -q '^<3>.*restart of hassos-supervisor.service FAILED' '$W/failing/out' && grep -q 'restart_failed' '$W/share/ga-supervisor-cli-watchdog.json'"

# --- marker not writable (fix 6): fail closed, loud, no restart on any tick
reset_boot; scen nomarker 300 no signature
STATE_OVERRIDE="$W/does/not/exist/ro"; mkdir -p "$W/does"; : > "$W/does/not"   # a FILE where the directory must be: mkdir and write both fail
tick $BOOT1; tick $BOOT1; tick $BOOT1
unset STATE_OVERRIDE
run_test "SCW-45" "marker cannot be written: NO restart on three ticks (fail closed)" "[ ! -f '$W/nomarker/systemctl.calls' ]"
run_test "SCW-46" "... logged at ERROR naming the marker and fail closed, state marker_write_failed" "grep -q '^<3>.*cannot write the attempt marker.*NOT restarting.*fail closed' '$W/nomarker/out' && grep -q 'marker_write_failed' '$W/share/ga-supervisor-cli-watchdog.json'"
rm -rf "$W/does"

# --- PIN (fix 4): the signature is the pinned Supervisor source line
PIN="$SCRIPT_DIR/supervisor-signature.pin"
pin_get() { sed -n "s/^$1=//p" "$PIN" | head -n 1; }
live_sig="$(sed -n "s/^SIGNATURE='\(.*\)'\$/\1/p" "$SUT" | head -n 1)"
run_test "SCW-60" "the live script's SIGNATURE is found (extraction must not skip)" "[ -n '$live_sig' ]"
run_test "SCW-61" "live script SIGNATURE == the pinned signature" "[ -n '$live_sig' ] && [ '$live_sig' = \"\$(pin_get SIGNATURE)\" ]"
run_test "SCW-62" "the pin is the cli instance of the pinned source format string" "[ \"\$(pin_get SOURCE_FORMAT | sed 's/%s/cli/;s/ in 30sec\$//')\" = \"\$(pin_get SIGNATURE)\" ]"
sup_ver="$(sed -n 's/^[[:space:]]*homeassistant_supervisor:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/version.yaml" | head -n 1)"
run_test "SCW-63" "version.yaml homeassistant_supervisor ($sup_ver) == the version the pin was checked against (a Supervisor bump must re-check, see the pin file)" "[ -n '$sup_ver' ] && [ '$sup_ver' = \"\$(pin_get CHECKED_SUPERVISOR_VERSION)\" ]"
if [ -n "${GA_SCW_SUPERVISOR_BASE_PY:-}" ]; then
  run_test "SCW-64" "Supervisor source ($GA_SCW_SUPERVISOR_BASE_PY) still contains the pinned format string" "grep -qF \"\$(pin_get SOURCE_FORMAT)\" '$GA_SCW_SUPERVISOR_BASE_PY'"
fi

# --- wiring (static): units exist, timer enabled, 2 min start
OVL="$ROOT/buildroot-external/rootfs-overlay"
run_test "SCW-50" "timer enabled via timers.target.wants and starts at +2 min" "test -e '$OVL/etc/systemd/system/timers.target.wants/ga-supervisor-cli-watchdog.timer' && grep -q '^OnBootSec=2min\$' '$OVL/etc/systemd/system/ga-supervisor-cli-watchdog.timer'"
run_test "SCW-51" "service runs the script and the script is executable" "grep -q '^ExecStart=/usr/sbin/ga-supervisor-cli-watchdog\$' '$OVL/etc/systemd/system/ga-supervisor-cli-watchdog.service' && test -x '$OVL/usr/sbin/ga-supervisor-cli-watchdog'"
run_test "SCW-52" "default age gate is 150 s" "grep -q 'GA_SCW_MIN_UPTIME:-150' '$SUT'"
suite_end
