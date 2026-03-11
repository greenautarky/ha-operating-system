#!/bin/sh
# Hardware driver integration tests - runs ON the device (iHost)
# Verifies that all critical hardware drivers probe successfully.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Hardware"

# --- WiFi (RTL8723DS via SDIO) ---

run_test "HW-01" "WiFi interface wlan0 present" \
  "ip link show wlan0 >/dev/null 2>&1"

run_test "HW-02" "rtw88_8723ds driver loaded (no eFuse errors)" \
  "dmesg | grep -q 'rtw_8723ds' && ! dmesg | grep -q 'failed to dump efuse'"

run_test "HW-03" "No SDIO/MMC errors in dmesg" \
  "! dmesg | grep -i 'mmc1' | grep -qi 'error\|failed\|timeout'"

if ip link show wlan0 >/dev/null 2>&1; then
  run_test_show "HW-04" "WiFi can scan networks" \
    "nmcli dev wifi list 2>/dev/null | head -3 || echo 'scan returned no results'"
else
  skip_test "HW-04" "WiFi scan" "wlan0 not present"
fi

# --- Ethernet ---

run_test "HW-05" "Ethernet interface eth0 present" \
  "ip link show eth0 >/dev/null 2>&1"

run_test_show "HW-06" "Ethernet link state" \
  "cat /sys/class/net/eth0/operstate 2>/dev/null"

# --- USB ---

run_test "HW-07" "USB subsystem functional" \
  "ls /sys/bus/usb/devices/ >/dev/null 2>&1"

if command -v lsusb >/dev/null 2>&1; then
  run_test_show "HW-08" "USB devices enumerated" \
    "lsusb 2>/dev/null | head -5"
else
  run_test_show "HW-08" "USB devices enumerated" \
    "ls /sys/bus/usb/devices/*/product 2>/dev/null | while read f; do echo \"\$(cat \$f)\"; done | head -5"
fi

# --- Zigbee dongle ---

run_test "HW-09" "Zigbee serial device present" \
  "ls /dev/ttyUSB* /dev/ttyACM* >/dev/null 2>&1"

# --- eMMC ---

run_test "HW-10" "eMMC block device present" \
  "ls /dev/mmcblk* >/dev/null 2>&1"

run_test_show "HW-11" "Root filesystem type" \
  "mount | grep 'on / ' | awk '{print \$5}'"

# --- Kernel health ---

run_test "HW-12" "Kernel not tainted" \
  "[ \"\$(cat /proc/sys/kernel/tainted 2>/dev/null)\" = '0' ]"

run_test "HW-13" "No critical driver errors in dmesg" \
  "! dmesg | grep -iE 'probe.*failed|driver.*error|firmware.*failed' | grep -v 'rtw_8723ds' | grep -qi 'fail\|error'"

# --- Thermal ---

if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
  TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
  TEMP_C=$((TEMP / 1000))
  run_test "HW-14" "CPU temperature in safe range (<85C)" \
    "[ $TEMP_C -lt 85 ]"
  run_test_show "HW-14b" "CPU temperature" \
    "echo '${TEMP_C}°C'"
else
  skip_test "HW-14" "CPU temperature" "thermal_zone0 not found"
fi

# --- Watchdog ---

run_test "HW-15" "Watchdog device present" \
  "ls /dev/watchdog* >/dev/null 2>&1"

# --- LEDs (iHost-specific) ---

if [ -d /sys/class/leds ]; then
  run_test_show "HW-16" "LED sysfs entries" \
    "ls /sys/class/leds/ 2>/dev/null | tr ' ' '\n' | head -5"
else
  skip_test "HW-16" "LED sysfs entries" "no /sys/class/leds"
fi

# --- Summary dmesg scan ---

DMESG_ERRS=$(dmesg | grep -ciE 'error|fail' 2>/dev/null || echo 0)
run_test_show "HW-SUM" "Total dmesg error/fail mentions" \
  "echo '$DMESG_ERRS lines (review with: dmesg | grep -iE error.fail)'"

suite_end
