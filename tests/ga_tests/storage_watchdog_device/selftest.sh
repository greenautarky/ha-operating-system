#!/bin/sh
# Host-side selftest of storage_watchdog_device/test.sh. One fixture is the status file the
# LIVE ga-storage-watchdog writes (run for real, 3 ticks, stub dd/notify as in
# storage_watchdog/selftest.sh would, here with the real dd on a temp dir), so suite and writer
# cannot drift. Must-PASS: armed, flag on and off with the config agreeing. Must-FAIL: unit
# without reboot-force, inactive service, stale / unarmed / failing status, the running flag
# differing from the config, a missing or wrong-size probe file, STORAGE DEAD in the journal.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/devsuite_selftest.sh"
ds_init
OVL="$DS_ROOT/../buildroot-external/rootfs-overlay"
WD="$OVL/usr/sbin/ga-storage-watchdog"
NOW=1800000000
mkdir -p "$W/data"

cat > "$W/bin/systemctl" <<'STUB'
#!/bin/sh
case "$*" in
  is-active*) echo "${FAKE_ACTIVE:-active}" ;;
  show*) cat "$FAKE_SHOW" ;;
esac
STUB
cat > "$W/bin/journalctl" <<'STUB'
#!/bin/sh
cat "${FAKE_JOURNAL:-/dev/null}"
STUB
chmod +x "$W/bin/"*

good() {
  printf 'Type=notify\nFailureAction=reboot-force\nWatchdogUSec=2min\n' > "$W/show"
  printf '{"schema_version":1,"ts":%s,"state":"armed","armed":true,"reboot_enabled":false,"consecutive_ok":9,"consecutive_fail":0,"last_ok_ts":%s,"reason":"","arm_after":3,"probe_file":"x"}\n' $((NOW - 20)) $((NOW - 20)) > "$W/status.json"
  printf 'GA_STORAGE_WD_REBOOT=0\n' > "$W/conf.default"; rm -f "$W/conf.override" "$W/journal"
  head -c 4096 /dev/zero > "$W/probe"
}
run() { ds_run storage_watchdog_device FAKE_SHOW="$W/show" GA_SWDD_BIN="$WD" GA_SWDD_STATUS="$W/status.json" GA_SWDD_PROBE="$W/probe" \
  GA_SWDD_CONF_LIB="$OVL/usr/libexec/ga-services-conf.sh" GA_SWDD_CONF_DEFAULT="$W/conf.default" GA_SWDD_CONF_OVERRIDE="$W/conf.override" \
  GA_SWDD_NOW=$NOW GA_DEVT_WAIT_S=1 "$@"; }

echo "== known-good: armed, flag off (baked default)"
good; run
for i in SWDD-01 SWDD-02 SWDD-03 SWDD-04 SWDD-05 SWDD-06 SWDD-07; do ds_expect "$i" PASS "armed, detection only"; done
ds_expect SWDD-10 SKIP "fault injection is bench-only"

echo "== known-good: flag ON through the override (the K31 soak shape)"
good; printf 'GA_STORAGE_WD_REBOOT=1\n' > "$W/conf.override"; sed -i 's/"reboot_enabled":false/"reboot_enabled":true/' "$W/status.json"; run
ds_expect SWDD-05 PASS "override says 1, the running process says true"
for i in SWDD-01 SWDD-02 SWDD-03 SWDD-04 SWDD-06 SWDD-07; do ds_expect "$i" PASS "armed, reboot on"; done

echo "== the file the LIVE watchdog writes is accepted by SWDD-03 (producer and consumer)"
cat > "$W/bin/systemd-notify" <<'STUB'
#!/bin/sh
exit 0
STUB
# tmpfs cannot O_DIRECT: the stub dd drops the direct flags and does the real I/O
REALDD="$(command -v dd)"
cat > "$W/bin/dd" <<STUB
#!/bin/sh
for a in "\$@"; do case "\$a" in iflag=direct|oflag=direct) ;; *) set -- "\$@" "\$a" ;; esac; shift; done
exec $REALDD "\$@"
STUB
chmod +x "$W/bin/systemd-notify" "$W/bin/dd"
PATH="$W/bin:$PATH" GA_STORAGE_WD_STATUS_FILE="$W/live.json" GA_STORAGE_WD_PROBE_FILE="$W/data/probe" GA_STORAGE_WD_RUN_DIR="$W/wdrun" GA_STORAGE_WD_KMSG=/dev/null GA_STORAGE_WD_PMSG=/dev/null \
  GA_STORAGE_WD_NOTIFY="$W/bin/systemd-notify" GA_STORAGE_WD_MAX_TICKS=4 GA_STORAGE_WD_INTERVAL_S=0 GA_STORAGE_WD_ARM_AFTER=2 GA_STORAGE_WD_WRITE_EVERY=2 \
  GA_STORAGE_WD_CONF_DEFAULT="$W/conf.default" GA_STORAGE_WD_CONF_OVERRIDE="$W/none" GA_SERVICES_CONF_LIB="$OVL/usr/libexec/ga-services-conf.sh" sh "$WD" >/dev/null 2>&1
good; cp "$W/live.json" "$W/status.json"
NOW_LIVE=$(date +%s)
ds_run storage_watchdog_device FAKE_SHOW="$W/show" GA_SWDD_BIN="$WD" GA_SWDD_STATUS="$W/status.json" GA_SWDD_PROBE="$W/data/probe" \
  GA_SWDD_CONF_LIB="$OVL/usr/libexec/ga-services-conf.sh" GA_SWDD_CONF_DEFAULT="$W/conf.default" GA_SWDD_CONF_OVERRIDE="$W/conf.override" GA_SWDD_NOW=$NOW_LIVE GA_DEVT_WAIT_S=1
ds_expect SWDD-03 PASS "status file written by the live ga-storage-watchdog"
ds_expect SWDD-04 PASS "...which armed after the good probes"
ds_expect SWDD-05 PASS "...with the flag the config holds"

echo "== must-flag"
good; printf 'Type=notify\nFailureAction=none\nWatchdogUSec=2min\n' > "$W/show"; run;   ds_expect SWDD-01 FAIL "unit without reboot-force"
good; printf 'Type=simple\nFailureAction=reboot-force\nWatchdogUSec=2min\n' > "$W/show"; run; ds_expect SWDD-01 FAIL "unit not Type=notify"
good; printf 'Type=notify\nFailureAction=reboot-force\nWatchdogUSec=0\n' > "$W/show"; run; ds_expect SWDD-01 FAIL "no WatchdogSec"
good; run FAKE_ACTIVE=failed;                                                              ds_expect SWDD-02 FAIL "service not active"
good; sed -i "s/\"ts\":$((NOW - 20))/\"ts\":$((NOW - 500))/" "$W/status.json"; run;      ds_expect SWDD-03 FAIL "status 500 s old"
good; sed -i 's/"schema_version":1/"schema_version":2/' "$W/status.json"; run;           ds_expect SWDD-03 FAIL "unknown schema"
good; sed -i 's/"state":"armed","armed":true/"state":"unarmed","armed":false/' "$W/status.json"; run; ds_expect SWDD-04 FAIL "never armed"
good; sed -i 's/"state":"armed"/"state":"failing"/; s/"consecutive_fail":0/"consecutive_fail":3/' "$W/status.json"; run; ds_expect SWDD-04 FAIL "probe failing right now"
good; printf 'GA_STORAGE_WD_REBOOT=1\n' > "$W/conf.override"; run;                       ds_expect SWDD-05 FAIL "config says 1, the process runs with false (edited, not restarted)"
good; rm -f "$W/conf.default"; run;                                                       ds_expect SWDD-05 FAIL "config unreadable"
good; rm -f "$W/probe"; run;                                                              ds_expect SWDD-06 FAIL "no probe file"
good; head -c 100 /dev/zero > "$W/probe"; run;                                            ds_expect SWDD-06 FAIL "probe file of the wrong size"
good; printf '%s\n' "ga-storage-watchdog: STORAGE DEAD: write probe failed" > "$W/journal"; run FAKE_JOURNAL="$W/journal"; ds_expect SWDD-07 FAIL "STORAGE DEAD in the journal"

ds_done
