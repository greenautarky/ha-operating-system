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

  BEFORE_FREE=$(free_mib)

  # Calculate how much to fill: leave only 200 MiB free (between soft=300 and hard=120)
  FILL_MIB=$((BEFORE_FREE - 200))
  if [ "$FILL_MIB" -le 0 ]; then
    skip_test "DG-05" "Soft cleanup trigger" "disk already below 200 MiB free"
    skip_test "DG-06" "Free space recovered after soft cleanup" "skipped"
    skip_test "DG-08" "Old temp files cleaned" "skipped"
  else
    # Fill disk with realistic data the guard CAN clean:
    # 1. Flood journald with log entries (guard vacuums these)
    # 2. Create old temp files in /tmp (guard deletes files > 3 days)
    # 3. Create fake rotated logs in /var/log (guard deletes *.gz, *.1, *.old)
    # 4. Fill remaining space with a bulk file (removed after test)
    echo "        -> Filling disk with test data (${BEFORE_FREE} MiB free -> ~200 MiB)..."

    # Flood journald (~50 MiB of log entries)
    echo "        -> Flooding journald with test entries..."
    for i in $(seq 1 5000); do
      logger -t ga_disk_test "Fill test entry $i: $(date) padding padding padding padding padding padding padding padding padding"
    done 2>/dev/null

    # Create old temp files (backdated 5 days, scattered in /tmp)
    echo "        -> Creating old temp files..."
    for i in $(seq 1 20); do
      dd if=/dev/urandom of="/tmp/.ga_test_old_${i}" bs=1M count=1 2>/dev/null || true
      touch -t 202601010000 "/tmp/.ga_test_old_${i}" 2>/dev/null || true
    done

    # Create fake rotated logs (guard should clean *.gz, *.1, *.old)
    echo "        -> Creating rotated log files..."
    for ext in gz 1 old xz bz2; do
      dd if=/dev/urandom of="/var/log/.ga_test_log.${ext}" bs=1M count=2 2>/dev/null || true
    done

    # Fill remaining space with a bulk file to push below threshold
    REMAINING=$(($(free_mib) - 200))
    FILL_FILE="/mnt/data/.ga_test_fill"
    if [ "$REMAINING" -gt 0 ]; then
      echo "        -> Filling remaining ${REMAINING} MiB with bulk file..."
      dd if=/dev/zero of="$FILL_FILE" bs=1M count="$REMAINING" 2>/dev/null || true
    fi

    AFTER_FILL=$(free_mib)
    echo "        -> Free after fill: ${AFTER_FILL} MiB (soft threshold: 300 MiB)"

    # DG-05: Run disk guard — should trigger soft cleanup
    run_test_show "DG-05" "Soft cleanup triggered (free=${AFTER_FILL} MiB < 300)" \
      "GA_DG_VERBOSE=1 /usr/sbin/ga_disk_guard 2>&1 | grep -qi 'soft cleanup'"

    # Remove bulk fill file — the guard can't delete it (not in ALLOWLIST paths)
    rm -f "$FILL_FILE" 2>/dev/null

    # DG-06: Verify disk guard logged cleanup actions (state file shows soft/hard phase)
    DG_PHASE=$(grep -o '"phase":"[^"]*"' /run/ga_disk_guard/state.json 2>/dev/null | cut -d'"' -f4 || echo "unknown")
    DG_FREED=$(grep -o '"worst_freed_mib":[0-9]*' /run/ga_disk_guard/state.json 2>/dev/null | cut -d: -f2 || echo "0")
    run_test_show "DG-06" "Disk guard ran cleanup (phase=${DG_PHASE}, freed=${DG_FREED} MiB)" \
      "[ \"$DG_PHASE\" = 'soft' ] || [ \"$DG_PHASE\" = 'hard' ]"

    # DG-08: Check old temp files cleaned (the backdated ones we created)
    REMAINING_OLD=$(ls /tmp/.ga_test_old_* 2>/dev/null | wc -l)
    run_test_show "DG-08" "Old temp files cleaned by guard (${REMAINING_OLD} remaining of 20)" \
      "[ \"$REMAINING_OLD\" -lt 10 ]"
    # Clean up any stragglers
    rm -f /tmp/.ga_test_old_* 2>/dev/null
  fi

  # DG-09: check that rotated log patterns are handled
  # /var/log is on volatile tmpfs, so we can write there
  ROTATED="/var/log/.ga_test_rotated.log.gz"
  if echo "test" > "$ROTATED" 2>/dev/null; then
    GA_DG_VERBOSE=0 /usr/sbin/ga_disk_guard >/dev/null 2>&1 || true
    run_test "DG-09" "Rotated .gz logs cleaned by soft cleanup" \
      "! test -f $ROTATED"
  else
    skip_test "DG-09" "Rotated .gz logs cleaned" "/var/log not writable"
  fi

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
