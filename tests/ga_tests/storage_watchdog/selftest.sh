#!/bin/sh
# ga-storage-watchdog — the LIVE script run for real against a fault-injectable
# probe directory. No device. (Odoo #2098)
#
# The subject is buildroot-external/rootfs-overlay/usr/sbin/ga-storage-watchdog
# itself. `dd`, `systemd-notify` and `sleep` are stubs on a private PATH: the
# dd stub performs the real I/O on a tmpfs/temp file but, per TICK, can answer
# EIO, hang, answer slowly, return corrupt data or make the file vanish; the
# sleep stub is the clock (one `sleep 0` = one tick). The notify stub records
# every WATCHDOG=1 with the tick it was sent in — "did it ping at tick N" is the
# observable that systemd's WatchdogSec turns into a reboot.
#
# Fixture families (working-method rule 51):
#   MUST-PASS  (never withhold a ping): healthy disk incl. write probes; probe
#              file missing on a healthy FS (re-created); EIO/hang before the
#              watchdog is ARMED; any failure with the reboot flag OFF; recovery.
#   MUST-FIRE  (ping withheld, reason in kmsg, status "failing"): after arming,
#              with GA_STORAGE_WD_REBOOT=1 — EIO on read, EIO on the write
#              probe, a hang, a slow read, corrupt read-back.
#   STATIC     unit carries Type=notify / WatchdogSec / FailureAction=
#              reboot-force, is enabled, flag defaults to 0 in ga-services.conf,
#              WatchdogSec covers >= 3 missed ticks of the LIVE cadence.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
suite_start "ga-storage-watchdog (live script, injected faults)"

ROOT="$SCRIPT_DIR/../../.."
OVL="$ROOT/buildroot-external/rootfs-overlay"
WD="${GA_STORAGE_WATCHDOG_BIN:-$OVL/usr/sbin/ga-storage-watchdog}"
UNIT="$OVL/etc/systemd/system/ga-storage-watchdog.service"
export GA_SERVICES_CONF_LIB="$OVL/usr/libexec/ga-services-conf.sh"

run_test "SWD-00" "the watchdog script exists and is executable" "test -x '$WD'"

W="$(mktemp -d "${TMPDIR:-/tmp}/storage_wd.XXXXXX")"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/data" "$W/run"
PF="$W/data/probe"

REALDD="$(command -v dd)"
cat > "$W/bin/dd" <<STUB
#!/bin/sh
# strip the O_DIRECT flags (tmpfs may refuse them); remember if the probe file is touched
touch_probe=0; args=""
for a in "\$@"; do
  case "\$a" in iflag=direct|oflag=direct) continue ;; oflag=direct,*|iflag=direct,*) continue ;; esac
  case "\$a" in if=$PF|of=$PF) touch_probe=1 ;; esac
  args="\$args \$a"
done
if [ \$touch_probe = 1 ]; then
  t=\$(cat "$W/tick"); n=1; mode=ok
  for m in \$(cat "$W/schedule"); do mode=\$m; [ \$n -ge \$t ] && break; n=\$(( n + 1 )); done
  echo "tick \$t mode \$mode: dd\$args" >> "$W/dd.log"
  case "\$mode" in
    eio) echo "dd: error reading '$PF': Input/output error" >&2; exit 1 ;;
    hang) exec sleep 8 ;;
    slow) sleep 4 ;;
    corrupt) case "\$*" in *"if=$PF"*) printf 'garbage' > "$W/run/readback"; exit 0 ;; esac ;;
  esac
fi
exec $REALDD \$args
STUB
cat > "$W/bin/sleep" <<STUB
#!/bin/sh
if [ "\$1" = 0 ]; then
  t=\$(( \$(cat "$W/tick") + 1 )); echo \$t > "$W/tick"
  # "gone": the probe file disappears BETWEEN probes (healthy FS, someone cleaned it)
  n=1; mode=ok; for m in \$(cat "$W/schedule"); do mode=\$m; [ \$n -ge \$t ] && break; n=\$(( n + 1 )); done
  [ "\$mode" = gone ] && rm -f "$PF"
  exit 0
fi
exec /bin/sleep "\$@"
STUB
cat > "$W/bin/systemd-notify" <<STUB
#!/bin/sh
echo "tick \$(cat "$W/tick") \$*" >> "$W/notify.log"
STUB
chmod +x "$W"/bin/*

reset_all() {
  rm -rf "$W/data" "$W/run" "$W"/notify.log "$W"/dd.log "$W"/kmsg "$W"/status.json "$W"/out
  mkdir -p "$W/data" "$W/run"; echo 1 > "$W/tick"
  : > "$W/kmsg"
  printf 'GA_SERVICES_IP=127.0.0.1\n' > "$W/conf"       # baked default: flag line ABSENT
}
flag_on() { echo 'GA_STORAGE_WD_REBOOT=1' >> "$W/conf"; }
# wd SCHEDULE MAXTICKS — SCHEDULE = space separated mode per tick (last repeats)
wd() {
  echo "$1" > "$W/schedule"
  PATH="$W/bin:/usr/bin:/bin" \
  GA_STORAGE_WD_CONF_DEFAULT="$W/conf" GA_STORAGE_WD_CONF_OVERRIDE="$W/none" \
  GA_STORAGE_WD_PROBE_FILE="$PF" GA_STORAGE_WD_STATUS_FILE="$W/status.json" \
  GA_STORAGE_WD_KMSG="$W/kmsg" GA_STORAGE_WD_PMSG="$W/nopmsg" GA_STORAGE_WD_RUN_DIR="$W/run" \
  GA_STORAGE_WD_INTERVAL_S=0 GA_STORAGE_WD_WRITE_EVERY="${WRITE_EVERY:-4}" GA_STORAGE_WD_ARM_AFTER=3 \
  GA_STORAGE_WD_PROBE_TIMEOUT_S=2 GA_STORAGE_WD_MAX_TICKS="$2" \
  sh "$WD" > "$W/out" 2>&1
  WD_RC=$?
}
pings()      { grep -c ' WATCHDOG=1$' "$W/notify.log" 2>/dev/null || true; }
pinged_at()  { grep -q "^tick $1 WATCHDOG=1\$" "$W/notify.log"; }
st()         { sed -n "s/.*\"$1\":\"\{0,1\}\([^,\"}]*\).*/\1/p" "$W/status.json" | head -1; }

# ═══════════════════════════════════════════ MUST-PASS
reset_all; wd "ok" 12
run_test "SWD-01" "healthy disk, 12 ticks incl. write probes: a ping on EVERY tick (12), exit 0" \
  "[ \"\$(pings)\" = 12 ] && [ \$WD_RC = 0 ]"
run_test "SWD-02" "…armed, status ok, no error line, no kmsg trail, a write probe really wrote" \
  "[ \"\$(st state)\" = armed ] && [ \"\$(st armed)\" = true ] && ! grep -q '^<[0-3]>' '$W/out' && [ ! -s '$W/kmsg' ] && [ \$(grep -c 'of=$PF' '$W/dd.log') -ge 2 ]"
run_test "SWD-03" "ready is sent at start and does not wait for the disk" \
  "head -1 '$W/notify.log' | grep -q -- '--ready'"

reset_all; wd "ok" 2
run_test "SWD-04" "ARMING: 2 good probes -> not armed" "[ \"\$(st armed)\" = false ]"
reset_all; wd "ok" 3
run_test "SWD-05" "ARMING: 3 good probes (N=3) -> armed" "[ \"\$(st armed)\" = true ]"

reset_all; flag_on; wd "ok ok ok ok ok gone ok" 8
run_test "SWD-06" "probe file vanished on a healthy FS (flag ON, armed): re-created by a write probe, pings every tick, no kmsg" \
  "[ \"\$(pings)\" = 8 ] && [ -f '$PF' ] && [ ! -s '$W/kmsg' ]"

reset_all; flag_on; wd "eio" 8
run_test "SWD-07" "EIO from the very first probe (never armed), flag ON: keeps pinging, exit 0 (dead medium must not become a reboot loop)" \
  "[ \"\$(pings)\" = 8 ] && [ \$WD_RC = 0 ] && [ \"\$(st armed)\" = false ] && [ ! -s '$W/kmsg' ]"

reset_all; wd "ok ok ok eio" 10
run_test "SWD-08" "armed, EIO, but flag OFF (default): REPORTS (error line, kmsg reason, status failing) and still pings every tick" \
  "[ \"\$(pings)\" = 10 ] && grep -q '^<3>.*STORAGE DEAD.*reboot flag OFF' '$W/out' && grep -q 'Input/output error' '$W/kmsg' && [ \"\$(st state)\" = failing ] && [ \$WD_RC = 0 ]"

reset_all; flag_on; wd "ok ok ok ok eio ok ok" 8
run_test "SWD-09" "one transient EIO, flag ON: ping withheld exactly at that tick, resumes after, RECOVERED logged, state armed" \
  "! pinged_at 5 && pinged_at 6 && pinged_at 4 && [ \"\$(pings)\" = 7 ] && grep -q 'RECOVERED' '$W/out' && [ \"\$(st state)\" = armed ]"

# ═══════════════════════════════════════════ MUST-FIRE (after arming, flag ON)
reset_all; flag_on; wd "ok ok ok ok eio" 9
run_test "SWD-10" "EIO on the read probe: NO ping from tick 5 on (ticks 1-4 pinged), exit 0 after loop" \
  "pinged_at 4 && ! pinged_at 5 && ! pinged_at 9 && [ \"\$(pings)\" = 4 ]"
run_test "SWD-11" "…reason is in kmsg BEFORE the reboot (priority 2, with the EIO text), error line in the journal, status failing/reboot_enabled" \
  "grep -q '^<2>ga-storage-watchdog: storage watchdog:.*Input/output error.*rebooting' '$W/kmsg' && grep -q '^<3>.*STORAGE DEAD.*withholding WATCHDOG=1' '$W/out' && [ \"\$(st state)\" = failing ] && [ \"\$(st reboot_enabled)\" = true ]"

reset_all; flag_on; wd "ok ok ok hang" 7
run_test "SWD-12" "HANG (probe never returns) after arming: no ping from the hung tick on, 'did not return' reason" \
  "pinged_at 3 && ! pinged_at 4 && ! pinged_at 7 && grep -q 'did not return\|still blocked' '$W/kmsg'"

reset_all; flag_on; wd "ok ok ok slow" 5
run_test "SWD-13" "SLOW read (4 s > 2 s probe timeout) after arming: no ping" \
  "pinged_at 3 && ! pinged_at 4"

reset_all; flag_on; wd "ok ok ok ok corrupt" 6
run_test "SWD-14" "write probe (tick 5) whose read-back differs: no ping, 'read-back differs' reason" \
  "pinged_at 4 && ! pinged_at 5 && grep -q 'differs' '$W/kmsg'"

reset_all; flag_on; WRITE_EVERY=4 wd "ok ok ok ok eio" 5
run_test "SWD-15" "EIO exactly on the WRITE probe tick (5 = 4n+1): no ping" "! pinged_at 5"

# ═══════════════════════════════════════════ STATIC
run_test "SWD-20" "unit: Type=notify, NotifyAccess=all, WatchdogSec set, FailureAction=reboot-force, Restart=no" \
  "grep -q '^Type=notify' '$UNIT' && grep -q '^NotifyAccess=all' '$UNIT' && grep -q '^WatchdogSec=[0-9]' '$UNIT' && grep -q '^FailureAction=reboot-force' '$UNIT' && grep -q '^Restart=no' '$UNIT'"
run_test "SWD-21" "unit is enabled (multi-user.target.wants symlink resolves to it)" \
  "[ \"\$(readlink -f '$OVL/etc/systemd/system/multi-user.target.wants/ga-storage-watchdog.service')\" = \"\$(readlink -f '$UNIT')\" ]"
run_test "SWD-22" "reboot flag defaults to 0 in the baked ga-services.conf" \
  "grep -q '^GA_STORAGE_WD_REBOOT=0' '$OVL/etc/ga-services.conf'"
run_test "SWD-23" "the script reads that same flag name, and gates the ping on it" \
  "grep -q 'GA_STORAGE_WD_REBOOT' '$WD' && grep -q 'WD_REBOOT\" = 1' '$WD'"
cadence="$(sed -n 's/^INTERVAL_S="\${GA_STORAGE_WD_INTERVAL_S:-\([0-9]*\)}".*/\1/p' "$WD")"
tmo="$(sed -n 's/^PROBE_TIMEOUT_S="\${GA_STORAGE_WD_PROBE_TIMEOUT_S:-\([0-9]*\)}".*/\1/p' "$WD")"
wsec="$(sed -n 's/^WatchdogSec=\([0-9]*\)$/\1/p' "$UNIT")"
run_test "SWD-24" "WatchdogSec (live: ${wsec:-?}) covers >= 3 ticks and 2 intervals + timeout of the live cadence (${cadence:-?}s + ${tmo:-?}s timeout); extraction must find all three" \
  "[ -n '$cadence' ] && [ -n '$tmo' ] && [ -n '$wsec' ] && [ '$wsec' -ge \$(( 2 * $cadence + $tmo )) ] && [ '$wsec' -ge \$(( 3 * $cadence )) ]"

suite_end
