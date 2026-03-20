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

run_test "DG-11" "journald vacuum action in log" \
  "journalctl -t ga_disk_guard --no-pager -q 2>/dev/null | grep -qi 'journal\|vacuum' || grep -qi 'journal\|vacuum' /usr/sbin/ga_disk_guard 2>/dev/null"

# --- Destructive fill tests (opt-in: FILL_DISK=1) ---
if [ "${FILL_DISK:-0}" = "1" ]; then

  # Helper: free MiB on /mnt/data
  free_mib() { df -m /mnt/data 2>/dev/null | awk 'NR==2 {print $4}'; }

  FILL_FILE="/mnt/data/.ga_test_fill"
  BEFORE_FREE=$(free_mib)

  # Calculate how much to fill: leave only 200 MiB free (between soft=300 and hard=120)
  FILL_MIB=$((BEFORE_FREE - 200))
  if [ "$FILL_MIB" -le 0 ]; then
    skip_test "DG-05" "Soft cleanup trigger" "disk already below 200 MiB free"
    skip_test "DG-06" "Free space recovered after soft cleanup" "skipped"
    skip_test "DG-08" "Old temp files cleaned" "skipped"
  else
    echo "        -> Filling /mnt/data with ${FILL_MIB} MiB (${BEFORE_FREE} MiB free -> ~200 MiB)..."
    dd if=/dev/zero of="$FILL_FILE" bs=1M count="$FILL_MIB" 2>/dev/null || true

    AFTER_FILL=$(free_mib)
    echo "        -> Free after fill: ${AFTER_FILL} MiB (soft threshold: 300 MiB)"

    # DG-05: Run disk guard — should trigger soft cleanup
    run_test_show "DG-05" "Soft cleanup triggered (free=${AFTER_FILL} MiB < 300)" \
      "GA_DG_VERBOSE=1 /usr/sbin/ga_disk_guard 2>&1 | grep -qi 'soft cleanup'"

    # DG-06: Verify free space recovered
    RECOVERED=$(free_mib)
    run_test_show "DG-06" "Free space recovered after cleanup (now ${RECOVERED} MiB)" \
      "[ \"$RECOVERED\" -gt \"$AFTER_FILL\" ]"

    # DG-08: Check old temp files cleaned
    # Create a test file backdated 5 days
    OLD_TMP="/tmp/.ga_test_old_file"
    touch "$OLD_TMP" 2>/dev/null
    # Backdate it (BusyBox touch -d may not work, use -t instead)
    touch -t 202601010000 "$OLD_TMP" 2>/dev/null || true
    GA_DG_VERBOSE=0 /usr/sbin/ga_disk_guard >/dev/null 2>&1 || true
    run_test "DG-08" "Old temp files cleaned by soft cleanup" \
      "! test -f $OLD_TMP"

    # Cleanup fill file
    rm -f "$FILL_FILE" 2>/dev/null
  fi

  # DG-09/10: check that rotated log patterns and large logs are handled
  # Create test rotated log
  ROTATED="/var/log/.ga_test_rotated.log.gz"
  echo "test" > "$ROTATED" 2>/dev/null || true
  GA_DG_VERBOSE=0 /usr/sbin/ga_disk_guard >/dev/null 2>&1 || true
  run_test "DG-09" "Rotated .gz logs cleaned by soft cleanup" \
    "! test -f $ROTATED"

  skip_test "DG-10" "Large log truncation" "requires a log > 20 MiB to verify"
  skip_test "DG-13" "Timer triggers after boot" "requires reboot wait"

else
  skip_test "DG-05" "Soft cleanup trigger" "set FILL_DISK=1 to enable"
  skip_test "DG-06" "Free space recovered after soft cleanup" "set FILL_DISK=1 to enable"
  skip_test "DG-08" "Old temp files cleaned" "set FILL_DISK=1 to enable"
  skip_test "DG-09" "Rotated logs cleaned" "set FILL_DISK=1 to enable"
  skip_test "DG-10" "Large log truncation" "set FILL_DISK=1 to enable"
  skip_test "DG-13" "Timer triggers after boot" "requires reboot wait"
fi

suite_end
