#!/bin/sh
# Telemetry test suite - runs ON the device
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Telemetry"

run_test "TEL-01" "Telegraf service running" \
  "systemctl is-active telegraf"

run_test "TEL-02" "Fluent-Bit service running" \
  "systemctl is-active fluent-bit"

run_test "TEL-03" "GA_ENV set in telegraf env" \
  "grep -q 'GA_ENV=' /mnt/data/telegraf/env 2>/dev/null"

run_test "TEL-04" "GA_ENV set in fluent-bit env" \
  "grep -q 'GA_ENV=' /mnt/data/fluent-bit/env 2>/dev/null"

run_test "TEL-05" "DEVICE_UUID extracted (not unknown)" \
  "grep 'DEVICE_UUID=' /mnt/data/telegraf/env 2>/dev/null | grep -qv 'unknown'"

run_test "TEL-06" "DEVICE_UUID matches across services" \
  "[ \"\$(grep DEVICE_UUID /mnt/data/telegraf/env 2>/dev/null)\" = \"\$(grep DEVICE_UUID /mnt/data/fluent-bit/env 2>/dev/null)\" ]"

run_test "TEL-07" "Telegraf config on rootfs" \
  "systemctl cat telegraf 2>/dev/null | grep -q '/etc/telegraf/telegraf.conf'"

run_test "TEL-08" "Fluent-Bit config on rootfs" \
  "systemctl cat fluent-bit 2>/dev/null | grep -q '/etc/fluent-bit/fluent-bit.conf'"

run_test "TEL-09" "Telegraf no persistent errors (last 5 min)" \
  "! journalctl -u telegraf --since '5 min ago' --no-pager -q 2>/dev/null | grep -qi 'error.*output\|failed to write'"

run_test "TEL-10" "Fluent-Bit no persistent errors (last 5 min)" \
  "! journalctl -u fluent-bit --since '5 min ago' --no-pager -q 2>/dev/null | grep -qi 'error.*output\|connection refused'"

run_test "TEL-11" "Safe defaults in telegraf unit" \
  "systemctl cat telegraf 2>/dev/null | grep -q 'Environment=.*GA_ENV=dev'"

run_test_show "TEL-ENV" "Telegraf env file contents" \
  "cat /mnt/data/telegraf/env 2>/dev/null"

suite_end
