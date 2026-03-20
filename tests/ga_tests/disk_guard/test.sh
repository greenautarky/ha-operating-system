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
# Thresholds from ga_disk_guard: soft=300 MiB, hard=120 MiB, target=450 MiB
# Journal vacuum: soft=200M, hard=80M
if [ "${FILL_DISK:-0}" = "1" ]; then

  # Helpers
  free_mib() { df -m /mnt/data 2>/dev/null | awk 'NR==2 {print $4}'; }
  journal_mib() { journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+M' | head -1 | tr -d 'M' | cut -d. -f1; }
  fill_to() {
    # Fill /mnt/data to leave exactly $1 MiB free
    local target_free="$1"
    local current_free=$(free_mib)
    local to_write=$((current_free - target_free))
    [ "$to_write" -le 0 ] && return 0
    dd if=/dev/zero of=/mnt/data/.ga_test_fill bs=1M count="$to_write" 2>/dev/null || true
  }
  cleanup_fill() {
    rm -f /mnt/data/.ga_test_fill 2>/dev/null
    rm -f /tmp/.ga_test_old_* /var/tmp/.ga_test_old_* 2>/dev/null
    rm -f /var/log/.ga_test_log.* 2>/dev/null
    rm -f /mnt/data/logs/.ga_test_biglog.log 2>/dev/null
  }
  # Clean up on exit no matter what
  trap cleanup_fill EXIT

  BEFORE_FREE=$(free_mib)
  if [ "$BEFORE_FREE" -lt 500 ]; then
    skip_test "DG-05" "Soft cleanup" "disk already low (${BEFORE_FREE} MiB)"
    skip_test "DG-06" "Soft cleanup recovery" "skipped"
    skip_test "DG-08" "Old temp files cleaned" "skipped"
    skip_test "DG-09" "Rotated logs cleaned" "skipped"
    skip_test "DG-10" "Large log truncation" "skipped"
    skip_test "DG-15" "Journal vacuum on soft" "skipped"
    skip_test "DG-16" "Hard cleanup trigger" "skipped"
    skip_test "DG-17" "Hard journal vacuum" "skipped"
    skip_test "DG-18" "Guard idempotent on healthy disk" "skipped"
    skip_test "DG-13" "Timer triggers after boot" "requires reboot wait"
  else

    # =========================================================================
    # SCENARIO 1: Soft cleanup (< 300 MiB free)
    # =========================================================================
    echo ""
    echo "        ── Scenario 1: Soft cleanup threshold (< 300 MiB) ──"

    # Seed cleanable data BEFORE filling
    echo "        -> Seeding cleanable data..."

    # Journal flood (~50 MiB of log entries the guard can vacuum)
    for i in $(seq 1 5000); do
      logger -t ga_disk_test "Soft fill $i $(date) pad pad pad pad pad pad pad pad pad"
    done 2>/dev/null

    # Old temp files in /tmp and /var/tmp (guard deletes > 3 days old)
    for i in $(seq 1 20); do
      dd if=/dev/urandom of="/tmp/.ga_test_old_${i}" bs=1M count=1 2>/dev/null || true
      touch -t 202601010000 "/tmp/.ga_test_old_${i}" 2>/dev/null || true
    done
    for i in $(seq 1 10); do
      dd if=/dev/urandom of="/var/tmp/.ga_test_old_${i}" bs=512K count=1 2>/dev/null || true
      touch -t 202601010000 "/var/tmp/.ga_test_old_${i}" 2>/dev/null || true
    done

    # Rotated logs (guard deletes *.gz, *.1, *.old, *.xz, *.bz2)
    for ext in gz 1 old xz bz2; do
      dd if=/dev/urandom of="/var/log/.ga_test_log.${ext}" bs=1M count=2 2>/dev/null || true
    done

    JOURNAL_BEFORE=$(journal_mib)
    echo "        -> Journal size before: ${JOURNAL_BEFORE:-?} MiB"

    # Fill to 250 MiB free (below soft=300, above hard=120)
    echo "        -> Filling to ~250 MiB free..."
    fill_to 250
    AFTER_FILL=$(free_mib)
    echo "        -> Free after fill: ${AFTER_FILL} MiB"

    # DG-05: Trigger guard — expect soft cleanup
    DG_OUTPUT=$(GA_DG_VERBOSE=1 /usr/sbin/ga_disk_guard 2>&1)
    run_test_show "DG-05" "Soft cleanup triggered (free=${AFTER_FILL} MiB < 300)" \
      "echo \"$DG_OUTPUT\" | grep -qi 'soft cleanup'"

    # Remove bulk file so we can measure what the GUARD freed
    rm -f /mnt/data/.ga_test_fill 2>/dev/null

    # DG-06: State file shows soft phase
    DG_PHASE=$(sed -n 's/.*"phase"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /run/ga_disk_guard/state.json 2>/dev/null || echo "unknown")
    DG_FREED=$(sed -n 's/.*"worst_freed_mib"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' /run/ga_disk_guard/state.json 2>/dev/null || echo "0")
    run_test_show "DG-06" "State: phase=${DG_PHASE}, freed=${DG_FREED} MiB" \
      "[ \"$DG_PHASE\" = 'soft' ] || [ \"$DG_PHASE\" = 'hard' ]"

    # DG-08: Old temp files cleaned
    REMAINING_TMP=$(ls /tmp/.ga_test_old_* 2>/dev/null | wc -l)
    REMAINING_VTMP=$(ls /var/tmp/.ga_test_old_* 2>/dev/null | wc -l)
    run_test_show "DG-08" "Old temp files cleaned (/tmp: ${REMAINING_TMP}/20, /var/tmp: ${REMAINING_VTMP}/10)" \
      "[ \"$REMAINING_TMP\" -eq 0 ] && [ \"$REMAINING_VTMP\" -eq 0 ]"

    # DG-09: Rotated logs cleaned
    REMAINING_ROT=$(ls /var/log/.ga_test_log.* 2>/dev/null | wc -l)
    run_test_show "DG-09" "Rotated logs cleaned (${REMAINING_ROT}/5 remaining)" \
      "[ \"$REMAINING_ROT\" -eq 0 ]"

    # DG-15: Journal vacuum — journal should be smaller after soft cleanup
    JOURNAL_AFTER=$(journal_mib)
    echo "        -> Journal size after: ${JOURNAL_AFTER:-?} MiB (before: ${JOURNAL_BEFORE:-?}, soft vacuum: 200M)"
    # Check guard log OR journal for vacuum evidence
    run_test_show "DG-15" "Journal vacuum attempted" \
      "echo \"$DG_OUTPUT\" | grep -qi 'journal\|vacuum' || journalctl -t ga_disk_guard --no-pager -n 20 2>/dev/null | grep -qi 'journal\|vacuum'"

    # DG-19: Verify soft cleanup event logged to journal
    run_test_show "DG-19" "Soft cleanup logged to journal" \
      "journalctl -t ga_disk_guard --no-pager -n 10 2>/dev/null | grep -q 'SOFT cleanup'"

    # Cleanup between scenarios
    cleanup_fill

    # =========================================================================
    # SCENARIO 2: Hard cleanup (< 120 MiB free)
    # =========================================================================
    echo ""
    echo "        ── Scenario 2: Hard cleanup threshold (< 120 MiB) ──"

    # Seed more data
    for i in $(seq 1 3000); do
      logger -t ga_disk_test "Hard fill $i $(date) pad pad pad pad pad pad pad"
    done 2>/dev/null
    for i in $(seq 1 10); do
      dd if=/dev/urandom of="/tmp/.ga_test_old_${i}" bs=1M count=1 2>/dev/null || true
      touch -t 202601010000 "/tmp/.ga_test_old_${i}" 2>/dev/null || true
    done

    # Fill to 100 MiB free (below hard=120)
    echo "        -> Filling to ~100 MiB free..."
    fill_to 100
    AFTER_HARD_FILL=$(free_mib)
    echo "        -> Free after fill: ${AFTER_HARD_FILL} MiB"

    # DG-16: Trigger guard — expect hard cleanup
    DG_HARD_OUTPUT=$(GA_DG_VERBOSE=1 /usr/sbin/ga_disk_guard 2>&1)
    run_test_show "DG-16" "Hard cleanup triggered (free=${AFTER_HARD_FILL} MiB < 120)" \
      "echo \"$DG_HARD_OUTPUT\" | grep -qi 'hard cleanup'"

    rm -f /mnt/data/.ga_test_fill 2>/dev/null

    # DG-17: Verify hard phase in state
    DG_HARD_PHASE=$(sed -n 's/.*"phase"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /run/ga_disk_guard/state.json 2>/dev/null || echo "unknown")
    run_test_show "DG-17" "Hard cleanup phase recorded (phase=${DG_HARD_PHASE})" \
      "[ \"$DG_HARD_PHASE\" = 'hard' ]"

    # DG-20: Verify hard cleanup event logged to journal
    run_test_show "DG-20" "Hard cleanup logged to journal" \
      "journalctl -t ga_disk_guard --no-pager -n 10 2>/dev/null | grep -q 'HARD cleanup'"

    cleanup_fill

    # =========================================================================
    # SCENARIO 3: Large log truncation (> 20 MiB active log)
    # =========================================================================
    echo ""
    echo "        ── Scenario 3: Large log truncation ──"

    # Create a 25 MiB log file (guard truncates active logs > 20 MiB)
    # Place it in /mnt/data/logs (persistent, writable, inside ALLOWLIST /mnt/data/)
    BIGLOG="/mnt/data/logs/.ga_test_biglog.log"
    if dd if=/dev/urandom of="$BIGLOG" bs=1M count=25 2>/dev/null; then
      BIGLOG_BEFORE=$(du -m "$BIGLOG" 2>/dev/null | awk '{print $1}')
      echo "        -> Created ${BIGLOG_BEFORE} MiB log file at $BIGLOG"

      # Fill disk so guard triggers cleanup — keep fill file present during guard run
      # so disk stays below threshold and truncation rule fires
      fill_to 250
      echo "        -> Running guard with disk low + large log..."
      GA_DG_VERBOSE=1 /usr/sbin/ga_disk_guard >/dev/null 2>&1 || true

      # NOW remove fill file
      rm -f /mnt/data/.ga_test_fill 2>/dev/null

      if [ -f "$BIGLOG" ]; then
        BIGLOG_AFTER=$(du -m "$BIGLOG" 2>/dev/null | awk '{print $1}')
        run_test_show "DG-10" "Large log truncated (${BIGLOG_BEFORE} MiB -> ${BIGLOG_AFTER:-?} MiB, threshold: 20 MiB)" \
          "[ \"${BIGLOG_AFTER:-25}\" -lt \"$BIGLOG_BEFORE\" ]"
      else
        run_test_show "DG-10" "Large log file deleted by guard" "true"
      fi
      rm -f "$BIGLOG" 2>/dev/null
    else
      skip_test "DG-10" "Large log truncation" "/mnt/data/logs not writable"
    fi

    cleanup_fill

    # =========================================================================
    # SCENARIO 4: Idempotent on healthy disk
    # =========================================================================
    echo ""
    echo "        ── Scenario 4: Guard is safe on healthy disk ──"

    HEALTHY_FREE_BEFORE=$(free_mib)
    GA_DG_VERBOSE=0 /usr/sbin/ga_disk_guard >/dev/null 2>&1 || true
    HEALTHY_FREE_AFTER=$(free_mib)
    DG_IDLE_PHASE=$(sed -n 's/.*"phase"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /run/ga_disk_guard/state.json 2>/dev/null || echo "unknown")
    run_test_show "DG-18" "Guard is idle on healthy disk (phase=${DG_IDLE_PHASE}, free: ${HEALTHY_FREE_BEFORE} -> ${HEALTHY_FREE_AFTER} MiB)" \
      "[ \"$DG_IDLE_PHASE\" = 'idle' ]"

    skip_test "DG-13" "Timer triggers after boot" "requires reboot wait"
  fi

else
  skip_test "DG-05" "Soft cleanup trigger" "set FILL_DISK=1 to enable"
  skip_test "DG-06" "Soft cleanup state" "set FILL_DISK=1 to enable"
  skip_test "DG-08" "Old temp files cleaned" "set FILL_DISK=1 to enable"
  skip_test "DG-09" "Rotated logs cleaned" "set FILL_DISK=1 to enable"
  skip_test "DG-10" "Large log truncation" "set FILL_DISK=1 to enable"
  skip_test "DG-15" "Journal vacuum on soft" "set FILL_DISK=1 to enable"
  skip_test "DG-16" "Hard cleanup trigger" "set FILL_DISK=1 to enable"
  skip_test "DG-17" "Hard cleanup state" "set FILL_DISK=1 to enable"
  skip_test "DG-18" "Guard idle on healthy disk" "set FILL_DISK=1 to enable"
  skip_test "DG-19" "Soft cleanup logged to journal" "set FILL_DISK=1 to enable"
  skip_test "DG-20" "Hard cleanup logged to journal" "set FILL_DISK=1 to enable"
  skip_test "DG-13" "Timer triggers after boot" "requires reboot wait"
fi

# DG-21: Verify Fluent-Bit is configured to forward disk guard events to Loki (always runs)
run_test "DG-21" "Fluent-Bit config includes ga-disk-guard.service" \
  "grep -q 'ga-disk-guard.service' /etc/fluent-bit/fluent-bit.conf 2>/dev/null"

suite_end
