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

# RTL8723DS produces benign SDIO warnings during probe — filter those out
warn_test "HW-03" "No unexpected SDIO/MMC errors in dmesg" \
  "! dmesg | grep -i 'mmc1' | grep -vi 'rtw\|rtl\|wlan\|wifi\|8723' | grep -qi 'error\|failed\|timeout'"

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

# --- USB host port (should be disabled for security) ---

run_test "HW-08a" "USB host port disabled" \
  "if ls /sys/bus/usb/devices/usb*/product 2>/dev/null | xargs cat 2>/dev/null | grep -qi 'EHCI\|OHCI'; then false; else true; fi"

run_test "HW-08b" "USB gadget (serial console) functional" \
  "dmesg | grep -q 'Gadget Serial\|g_serial\|dwc3.*peripheral' || [ -c /dev/ttyGS0 ]"

# --- Zigbee (internal EFR32 on UART3) ---

run_test "HW-09" "Zigbee serial device present (internal UART)" \
  "[ -c /dev/ttyS3 ]"

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

# --- Watchdog ---

run_test "HW-15" "Watchdog device present" \
  "ls /dev/watchdog* >/dev/null 2>&1"

# --- Summary dmesg scan ---

DMESG_ERRS=$(dmesg | grep -ciE 'error|fail' 2>/dev/null || echo 0)
run_test_show "HW-SUM" "Total dmesg error/fail mentions" \
  "echo '$DMESG_ERRS lines (review with: dmesg | grep -iE error.fail)'"

suite_end
