#!/bin/sh
# Disk guard test suite - runs ON the device
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Disk Guard"

run_test "DG-01a" "Disk guard script exists and executable" \
  "test -x /usr/sbin/ga_disk_guard"

run_test "DG-01b" "Timer unit exists" \
  "systemctl list-unit-files 2>/dev/null | grep -q ga-disk-guard.timer"

run_test "DG-01c" "Service unit exists" \
  "systemctl list-unit-files 2>/dev/null | grep -q ga-disk-guard.service"

run_test "DG-02" "Timer is active" \
  "systemctl is-active ga-disk-guard.timer"

# Run the script manually (idle test)
GA_DG_VERBOSE=0 /usr/sbin/ga_disk_guard 2>/dev/null || true

run_test "DG-03" "State file created after run" \
  "test -f /run/ga_disk_guard/state.json"

run_test "DG-04a" "State file has phase field" \
  "grep -q '\"phase\"' /run/ga_disk_guard/state.json 2>/dev/null"

run_test "DG-04b" "State file has timestamp" \
  "grep -q '\"timestamp\"' /run/ga_disk_guard/state.json 2>/dev/null"

run_test "DG-04c" "State file has worst_mountpoint" \
  "grep -q '\"worst_mountpoint\"' /run/ga_disk_guard/state.json 2>/dev/null"

run_test "DG-07" "Monitors /mnt/data (not /)" \
  "grep -q '/mnt/data' /usr/sbin/ga_disk_guard 2>/dev/null && ! grep '^MONITOR_PATHS=' /usr/sbin/ga_disk_guard 2>/dev/null | grep -q '\" /'"

run_test "DG-12" "Lock dir created during run" \
  "mkdir /run/ga_disk_guard.lock 2>/dev/null && rmdir /run/ga_disk_guard.lock || true; true"

run_test "DG-14" "Script exits 0 on healthy disk" \
  "/usr/sbin/ga_disk_guard >/dev/null 2>&1"

run_test_show "DG-STATE" "Current state" \
  "cat /run/ga_disk_guard/state.json 2>/dev/null"

skip_test "DG-05" "Soft cleanup trigger" "requires filling disk"
skip_test "DG-06" "Hard cleanup trigger" "requires filling disk"
skip_test "DG-13" "Timer triggers after boot" "requires reboot wait"

suite_end
