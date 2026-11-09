#!/bin/sh
# ga-supervisor-cli-watchdog — the LIVE script against a fake docker / systemctl
# (Odoo #1706). No device. Shell under test: GA_T_SHELL (default sh).
#
# Fixture families (working-method rule 51):
#   MUST-ACT      deadlock (supervisor up >= N, no hassio_cli, install-retry
#                 signature in the log) -> exactly ONE restart.
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
# scenario files in $FAKE: sup_up_s (seconds the supervisor has run, absent =
# not running), cli (present = hassio_cli running), logfile (supervisor log)
case "$1" in
  inspect)
    case "$*" in
      *hassio_supervisor*)
        [ -f "$FAKE/sup_up_s" ] || { echo "false 0001-01-01T00:00:00Z"; exit 0; }
        s=$(cat "$FAKE/sup_up_s")
        echo "true $(date -u -d "@$((NOW0 - s))" '+%Y-%m-%dT%H:%M:%S').123456789Z" ;;
      *hassio_cli*)
        if [ -f "$FAKE/cli" ]; then echo true; else echo "Error: No such object" >&2; exit 1; fi ;;
    esac ;;
  logs) cat "$FAKE/logfile" 2>/dev/null ;;
esac
STUB
cat > "$W/bin/systemctl" <<'STUB'
#!/bin/sh
echo "$*" >> "$FAKE/systemctl.calls"
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

# scen <name> <sup_up_s|none> <cli yes|no> <log signature|plain|none>
scen() {
  FAKE="$W/$1"; rm -rf "$FAKE"; mkdir -p "$FAKE"; export FAKE
  [ "$2" = none ] || echo "$2" > "$FAKE/sup_up_s"
  [ "$3" = yes ] && : > "$FAKE/cli"
  case "$4" in
    signature) printf '%s\n%s\n' "$SIG" "$SIG" > "$FAKE/logfile" ;;
    plain) echo "$NOSIG" > "$FAKE/logfile" ;;
  esac
}
# tick <boot-id>: one timer tick. Output to $FAKE/out; restarts counted from systemctl calls.
tick() {
  printf '%s\n' "$1" > "$W/bootid"
  PATH="$W/bin:$PATH" NOW0="$NOW0" FAKE="$FAKE" \
  GA_SCW_NOW="$NOW0" GA_SCW_STATE_DIR="$W/run" GA_SCW_BOOTID="$W/bootid" \
  GA_SCW_PUBLISH="$W/bin/publish" GA_SCW_SHARE_FILE="$W/share/ga-supervisor-cli-watchdog.json" \
  GA_SCW_DOCKER="$W/bin/docker" GA_SCW_SYSTEMCTL="$W/bin/systemctl" \
  $SH "$SUT" >> "$FAKE/out" 2>&1
}
reset_boot() { rm -f "$W/run/ga-supervisor-cli-watchdog.attempted" "$W/share/"*; }
BOOT1=11111111-1111-1111-1111-111111111111
BOOT2=22222222-2222-2222-2222-222222222222

# --- MUST-ACT: deadlock -> exactly one restart, across many ticks
reset_boot; scen deadlock 300 no signature
tick $BOOT1; tick $BOOT1; tick $BOOT1; tick $BOOT1
run_test "SCW-10" "deadlock: exactly ONE restart over four ticks" "[ \"\$(grep -c '^restart hassos-supervisor.service\$' '$W/deadlock/systemctl.calls')\" = 1 ]"
run_test "SCW-11" "the restart is logged at ERROR (<3>) and names #1706" "grep -q '^<3>.*restarting hassos-supervisor.service ONCE.*#1706' '$W/deadlock/out'"
run_test "SCW-12" "status JSON published with state restarted + valid schema" "grep -q '\"state\":\"restarted\"' '$W/share/ga-supervisor-cli-watchdog.json' && grep -q '\"schema_version\":1' '$W/share/ga-supervisor-cli-watchdog.json'"
run_test "SCW-13" "already restarted this boot: ticks 2-4 stayed silent (one ERROR line only)" "[ \"\$(grep -c '^<3>' '$W/deadlock/out')\" = 1 ]"

# --- PER BOOT: the second boot may fire once again
scen deadlock2 300 no signature
tick $BOOT2; tick $BOOT2
run_test "SCW-20" "second boot (new boot id): fires once again, once" "[ \"\$(grep -c '^restart hassos-supervisor.service\$' '$W/deadlock2/systemctl.calls')\" = 1 ]"

# --- MUST-NOT-ACT
reset_boot; scen healthy 600 yes plain; tick $BOOT1; tick $BOOT1
run_test "SCW-30" "healthy (hassio_cli running): no restart" "[ ! -f '$W/healthy/systemctl.calls' ]"
run_test "SCW-31" "healthy: status ok published" "grep -q '\"state\":\"ok\"' '$W/share/ga-supervisor-cli-watchdog.json'"

reset_boot; scen young 120 no signature; tick $BOOT1
run_test "SCW-32" "normal first boot (supervisor up 120 s < N, cli not there yet, retries logged): no restart" "[ ! -f '$W/young/systemctl.calls' ]"

reset_boot; scen nosig 600 no plain; tick $BOOT1
run_test "SCW-33" "cli missing WITHOUT the deadlock signature: no restart" "[ ! -f '$W/nosig/systemctl.calls' ]"
run_test "SCW-34" "... and said so loudly at ERROR with state cli_missing_no_signature" "grep -q '^<3>.*NOT restarting' '$W/nosig/out' && grep -q 'cli_missing_no_signature' '$W/share/ga-supervisor-cli-watchdog.json'"

reset_boot; scen supdown none no signature; tick $BOOT1
run_test "SCW-35" "supervisor container not running: no restart" "[ ! -f '$W/supdown/systemctl.calls' ]"

reset_boot; scen coreoff 900 yes plain; tick $BOOT1
run_test "SCW-36" "Core intentionally stopped (cli up, no Core): no restart, Core is not part of the condition" "[ ! -f '$W/coreoff/systemctl.calls' ]"

reset_boot; scen healed 900 yes signature; tick $BOOT1
run_test "SCW-37" "cli running although the log still holds old install retries: no restart" "[ ! -f '$W/healed/systemctl.calls' ]"

# --- a failing restart is not retried
reset_boot; scen failing 300 no signature; : > "$W/failing/restart_fails"
tick $BOOT1; tick $BOOT1; tick $BOOT1
run_test "SCW-40" "restart fails: attempted once, never retried this boot" "[ \"\$(grep -c '^restart hassos-supervisor.service\$' '$W/failing/systemctl.calls')\" = 1 ]"
run_test "SCW-41" "restart failure logged at ERROR, state restart_failed" "grep -q '^<3>.*restart of hassos-supervisor.service FAILED' '$W/failing/out' && grep -q 'restart_failed' '$W/share/ga-supervisor-cli-watchdog.json'"

# --- wiring (static): units exist, timer enabled, 4 min start
OVL="$ROOT/buildroot-external/rootfs-overlay"
run_test "SCW-50" "timer enabled via timers.target.wants and starts at +4 min" "test -e '$OVL/etc/systemd/system/timers.target.wants/ga-supervisor-cli-watchdog.timer' && grep -q '^OnBootSec=4min\$' '$OVL/etc/systemd/system/ga-supervisor-cli-watchdog.timer'"
run_test "SCW-51" "service runs the script and the script is executable" "grep -q '^ExecStart=/usr/sbin/ga-supervisor-cli-watchdog\$' '$OVL/etc/systemd/system/ga-supervisor-cli-watchdog.service' && test -x '$OVL/usr/sbin/ga-supervisor-cli-watchdog'"
suite_end
