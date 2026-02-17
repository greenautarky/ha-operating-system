#!/bin/sh
# Boot timing test suite - runs ON the device
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Boot Timing"

run_test "BOOT-01" "Boot timing script exists and executable" \
  "test -x /usr/libexec/ga-boot-timing"

run_test "BOOT-02" "Script produces InfluxDB line protocol" \
  "/usr/libexec/ga-boot-timing 2>/dev/null | grep -q '^boot_timing'"

run_test "BOOT-03" "Kernel time present in output" \
  "/usr/libexec/ga-boot-timing 2>/dev/null | grep -qE 'kernel=[0-9]'"

run_test "BOOT-04a" "network_online milestone present" \
  "/usr/libexec/ga-boot-timing 2>/dev/null | grep -q 'network_online='"

run_test "BOOT-04b" "docker milestone present" \
  "/usr/libexec/ga-boot-timing 2>/dev/null | grep -q 'docker='"

run_test "BOOT-04c" "multi_user milestone present" \
  "/usr/libexec/ga-boot-timing 2>/dev/null | grep -q 'multi_user='"

run_test "BOOT-06" "Telegraf exec input configured" \
  "grep -q 'ga-boot-timing' /etc/telegraf/telegraf.conf 2>/dev/null"

run_test "BOOT-10" "Script handles errors gracefully (exit 0)" \
  "/usr/libexec/ga-boot-timing >/dev/null 2>&1"

run_test_show "BOOT-OUT" "Boot timing output" \
  "/usr/libexec/ga-boot-timing 2>/dev/null"

skip_test "BOOT-08" "Boot ID unique per boot" "requires 2+ reboots"
skip_test "BOOT-09" "Timing consistent after reboot" "requires reboot"

suite_end
