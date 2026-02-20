#!/bin/sh
# Config deployment verification - runs ON the device
# Verifies critical configs were correctly deployed to rootfs with expected content.
# Catches stale configs from failed builds or incomplete RAUC OTA updates.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Config Verify"

# --- Telegraf config ---
run_test "CFG-01" "telegraf.conf exists on rootfs" \
  "test -f /etc/telegraf/telegraf.conf"

run_test "CFG-02" "telegraf.conf has device_label tag" \
  "grep -q 'device_label' /etc/telegraf/telegraf.conf"

run_test "CFG-03" "telegraf.conf has uuid tag" \
  "grep -q 'uuid.*DEVICE_UUID' /etc/telegraf/telegraf.conf"

# --- Telegraf service ---
run_test "CFG-04" "telegraf.service has DEVICE_LABEL ExecStartPre" \
  "systemctl cat telegraf 2>/dev/null | grep -q 'DEVICE_LABEL.*ga-device-label'"

run_test "CFG-05" "telegraf.service has DEVICE_UUID ExecStartPre" \
  "systemctl cat telegraf 2>/dev/null | grep -q 'DEVICE_UUID.*core.uuid'"

run_test "CFG-06" "telegraf.service has DEVICE_LABEL safe default" \
  "systemctl cat telegraf 2>/dev/null | grep -q 'Environment=.*DEVICE_LABEL=unknown'"

# --- Fluent-Bit config ---
run_test "CFG-07" "fluent-bit.conf exists on rootfs" \
  "test -f /etc/fluent-bit/fluent-bit.conf"

run_test "CFG-08" "fluent-bit.conf has device_label in filter" \
  "grep -q 'device_label' /etc/fluent-bit/fluent-bit.conf"

run_test "CFG-09" "fluent-bit.conf has device_label in Loki labels" \
  "grep 'labels.*job=ihost' /etc/fluent-bit/fluent-bit.conf | grep -q 'device_label'"

# --- Fluent-Bit service ---
run_test "CFG-10" "fluent-bit.service has DEVICE_LABEL ExecStartPre" \
  "systemctl cat fluent-bit 2>/dev/null | grep -q 'DEVICE_LABEL.*ga-device-label'"

run_test "CFG-11" "fluent-bit.service has DEVICE_LABEL safe default" \
  "systemctl cat fluent-bit 2>/dev/null | grep -q 'Environment=.*DEVICE_LABEL=unknown'"

# --- Device label file ---
if [ -f /mnt/data/ga-device-label ]; then
  run_test_show "CFG-12" "ga-device-label file has valid content" \
    "cat /mnt/data/ga-device-label"
else
  # No label file — verify fallback works (env should show "unknown")
  run_test "CFG-12" "ga-device-label fallback (no label file, env=unknown)" \
    "grep -q 'DEVICE_LABEL=unknown' /mnt/data/telegraf/env 2>/dev/null"
fi

suite_end
