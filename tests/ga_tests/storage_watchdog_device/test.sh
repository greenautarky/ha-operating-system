#!/bin/sh
# storage_watchdog_device - ga-storage-watchdog (Odoo #2098, OS #1082) ON the device.
#
# The decisions (EIO, hang, slow, corrupt read-back, arming, the reboot flag) are proven
# host-side by tests/ga_tests/storage_watchdog/selftest.sh against the LIVE script. This
# suite is the READ-ONLY device half: is it installed, running, armed, fresh, and is the
# reboot flag the device holds the one the running process uses.
#
#   SWDD-01  script installed, unit has Type=notify, WatchdogSec=2min, FailureAction=reboot-force
#   SWDD-02  service is active
#   SWDD-03  status JSON (/run/ga-storage-watchdog.json) parses, schema 1, written in the
#            last 100 s (the loop ticks every 30 s)
#   SWDD-04  ARMED (state armed, armed true) - waits up to 240 s after boot (3 good probes)
#   SWDD-05  the reboot flag is readable AND the running process uses what the config says
#            (GA_STORAGE_WD_REBOOT in /etc/ga-services.conf + /mnt/data/ga-services.conf;
#            the script reads it ONCE at start, so a differing value means "edited, not
#            restarted"). The value is printed: 1 = a failing probe reboots the device.
#   SWDD-06  the probe file exists, one 4096-byte block, on the data partition
#   SWDD-07  no "STORAGE DEAD" in this boot's journal
#   SWDD-10  fault injection (EIO / hang) is SKIPPED: with the reboot flag on it would
#            reboot the device. Covered host-side; on-device only on a bench unit.
# Both boards (the script and unit are shared).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "ga-storage-watchdog on the device (Odoo #2098)"

BIN="${GA_SWDD_BIN:-/usr/sbin/ga-storage-watchdog}"
STATUS="${GA_SWDD_STATUS:-/run/ga-storage-watchdog.json}"
PROBE="${GA_SWDD_PROBE:-/mnt/data/.ga-storage-wd-probe}"
CONF_LIB="${GA_SWDD_CONF_LIB:-/usr/libexec/ga-services-conf.sh}"
CONF_DEFAULT="${GA_SWDD_CONF_DEFAULT:-/etc/ga-services.conf}"
CONF_OVERRIDE="${GA_SWDD_CONF_OVERRIDE:-/mnt/data/ga-services.conf}"
UNIT=ga-storage-watchdog.service
NOW="${GA_SWDD_NOW:-$(date +%s)}"

P=$(systemctl show -p Type -p WatchdogUSec -p FailureAction "$UNIT" 2>/dev/null | tr '\n' ' ')
case "$P" in
  *"Type=notify"*"FailureAction=reboot-force"*|*"FailureAction=reboot-force"*"Type=notify"*) _t=0 ;;
  *) _t=1 ;;
esac
# WatchdogUSec prints humanised ("2min") or raw ("120000000") depending on systemd
case "$P" in *"WatchdogUSec=2min"*|*"WatchdogUSec=120s"*|*"WatchdogUSec=120000000"*) _w=0 ;; *) _w=1 ;; esac
if [ -x "$BIN" ] && [ "$_t" = 0 ] && [ "$_w" = 0 ]; then _rc=0; else _rc=1; fi
show_verdict "SWDD-01" "installed; unit is Type=notify, WatchdogSec=2min, FailureAction=reboot-force" "$_rc" "$P"

if [ "$(systemctl is-active "$UNIT" 2>/dev/null)" = active ]; then _rc=0; else _rc=1; fi
show_verdict "SWDD-02" "$UNIT is active" "$_rc" "$(systemctl is-active "$UNIT" 2>/dev/null)"

# the first write may take a moment after (re)start; bounded wait, then assert for real
run_test_ready "SWDD-03a" "the status file exists" "test -s '$STATUS'" "${GA_DEVT_WAIT_S:-120}" "test -s '$STATUS'"
TS=$(jq -r '.ts // empty' "$STATUS" 2>/dev/null)
SV=$(jq -r '.schema_version // empty' "$STATUS" 2>/dev/null)
if [ -n "$TS" ] && [ "$SV" = 1 ] && [ $(( NOW - TS )) -le 100 ] && [ $(( NOW - TS )) -ge -30 ]; then _rc=0; else _rc=1; fi
show_verdict "SWDD-03" "status JSON: schema 1, written in the last 100 s" "$_rc" "ts=${TS:-none} age=$([ -n "$TS" ] && echo $(( NOW - TS )) || echo n/a)s"

armed_now() { [ "$(jq -r '.armed' "$STATUS" 2>/dev/null)" = true ]; }
if ! wait_for "${GA_DEVT_WAIT_S:-240}" armed_now; then printf '  (SWDD-04: not armed after %s s - asserting anyway)\n' "${GA_DEVT_WAIT_S:-240}"; fi
ST=$(jq -r '.state // "missing"' "$STATUS" 2>/dev/null)
if [ "$ST" = armed ] && armed_now; then _rc=0; else _rc=1; fi
show_verdict "SWDD-04" "the watchdog is ARMED (state armed)" "$_rc" "state=$ST consecutive_ok=$(jq -r '.consecutive_ok // "?"' "$STATUS" 2>/dev/null) consecutive_fail=$(jq -r '.consecutive_fail // "?"' "$STATUS" 2>/dev/null) reason='$(jq -r '.reason // ""' "$STATUS" 2>/dev/null)'"

# SWDD-05: two sources for one fact - the running process's flag (status file) and the config
# (the script itself falls back to 0 with a loud line when no config is readable; a device
# whose config is unreadable is a finding here, not a quiet 0)
CFG=$( (GA_STORAGE_WD_REBOOT=0; . "$CONF_LIB" 2>/dev/null && ga_load_services_conf "$CONF_DEFAULT" "$CONF_OVERRIDE" >/dev/null 2>&1 && echo "${GA_STORAGE_WD_REBOOT:-unset}" || echo unreadable) 2>/dev/null )
RUN=$(jq -r '.reboot_enabled | tostring' "$STATUS" 2>/dev/null)
case "$CFG:$RUN" in 1:true|0:false) _rc=0 ;; *) _rc=1 ;; esac
show_verdict "SWDD-05" "the reboot flag the process runs with equals the configured one" "$_rc" "configured GA_STORAGE_WD_REBOOT=$CFG, running reboot_enabled=$RUN ($([ "$RUN" = true ] && echo 'a failing probe REBOOTS this device' || echo 'detection only, no reboot'))"

PS=$(stat -c %s "$PROBE" 2>/dev/null)
if [ "$PS" = 4096 ]; then _rc=0; else _rc=1; fi
show_verdict "SWDD-06" "the probe file is one 4096-byte block on the data partition" "$_rc" "$PROBE size=${PS:-absent}"

DEAD=$(journalctl -t ga-storage-watchdog -b --no-pager -q 2>/dev/null | grep -c 'STORAGE DEAD')
if [ "$DEAD" = 0 ]; then _rc=0; else _rc=1; fi
show_verdict "SWDD-07" "no 'STORAGE DEAD' in this boot's journal" "$_rc" "$DEAD line(s)"

skip_test "SWDD-10" "fault injection (EIO / hang) makes the watchdog act" "destructive: with the reboot flag on it reboots the device - proven host-side (storage_watchdog/selftest.sh), on-device only on a bench unit"

suite_end
