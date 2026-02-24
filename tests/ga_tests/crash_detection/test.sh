#!/bin/sh
# Crash detection test suite - runs ON the device
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Crash Detection"

run_test "CRASH-01a" "ga-crash-marker service enabled" \
  "systemctl is-enabled ga-crash-marker"

run_test "CRASH-01b" "ga-boot-check service enabled" \
  "systemctl is-enabled ga-boot-check"

run_test "CRASH-02" "Crash marker file exists (active boot)" \
  "test -f /mnt/data/.ga_unclean_shutdown"

run_test "CRASH-06" "Previous boot logs accessible" \
  "journalctl -b -1 2>/dev/null | head -1 | grep -q ."

run_test "CRASH-07" "Multiple boots in journal" \
  "[ \$(journalctl --list-boots 2>/dev/null | wc -l) -ge 2 ]"

run_test "CRASH-08" "Crash log under 100KB limit" \
  "[ ! -f /mnt/data/crash_history.log ] || [ \$(stat -c%s /mnt/data/crash_history.log 2>/dev/null || echo 0) -lt 102400 ]"

run_test "CRASH-09" "Boot-check runs before crash-marker" \
  "systemctl show -p After ga-crash-marker.service 2>/dev/null | grep -q ga-boot-check"

run_test_show "CRASH-RES" "Boot check result this boot" \
  "journalctl -u ga-boot-check -b 0 --no-pager -q 2>/dev/null | tail -1"

skip_test "CRASH-03" "Clean shutdown removes marker" "requires reboot"
skip_test "CRASH-04" "Kernel panic detection" "host-side: run with crash_panic suite"
skip_test "CRASH-05" "Power loss detection" "requires physical action"

suite_end
