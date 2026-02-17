#!/bin/sh
# Watchdog test suite - runs ON the device
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Watchdog"

run_test "WDT-01" "Watchdog device exists" \
  "test -c /dev/watchdog || test -c /dev/watchdog0"

# Watchdog sysfs timeout may not be exposed on all hardware (e.g. iHost)
if [ -f /sys/class/watchdog/watchdog0/timeout ]; then
  run_test_show "WDT-02" "Watchdog timeout" \
    "cat /sys/class/watchdog/watchdog0/timeout 2>/dev/null"
  run_test "WDT-02b" "Timeout is non-zero" \
    "[ \$(cat /sys/class/watchdog/watchdog0/timeout 2>/dev/null || echo 0) -gt 0 ]"
else
  skip_test "WDT-02" "Watchdog timeout" "sysfs timeout not exposed"
  skip_test "WDT-02b" "Timeout is non-zero" "sysfs timeout not exposed"
fi

run_test "WDT-04" "System uptime increasing (not rebooting)" \
  "[ \$(awk '{print int(\$1)}' /proc/uptime) -gt 30 ]"

skip_test "WDT-03" "Watchdog triggers reboot on hang" "destructive"

suite_end
