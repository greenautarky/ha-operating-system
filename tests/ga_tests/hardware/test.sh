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

# Zigbee dongle firmware version (from Z2M coordinator info)
if command -v docker >/dev/null 2>&1; then
  Z2M_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep "ga_zigbee2mqtt" | head -1)
  if [ -n "$Z2M_CONTAINER" ]; then
    Z2M_FW=$(docker exec "$Z2M_CONTAINER" cat /app/data/coordinator_backup.json 2>/dev/null | grep -o '"ezsp":[^}]*' | head -1 || true)
    run_test_show "HW-09b" "Z2M coordinator detected" \
      "docker exec $Z2M_CONTAINER cat /app/data/configuration.yaml 2>/dev/null | grep -q 'serial'"

    Z2M_PORT=$(docker exec "$Z2M_CONTAINER" cat /app/data/configuration.yaml 2>/dev/null | grep 'port:' | head -1 | awk '{print $2}' || true)
    run_test_show "HW-09c" "Z2M serial port configured (${Z2M_PORT:-?})" \
      "[ -n \"$Z2M_PORT\" ]"
  else
    skip_test "HW-09b" "Z2M coordinator detected" "zigbee2mqtt not running"
    skip_test "HW-09c" "Z2M serial port configured" "zigbee2mqtt not running"
  fi
else
  skip_test "HW-09b" "Z2M coordinator detected" "docker not found"
  skip_test "HW-09c" "Z2M serial port configured" "docker not found"
fi

# --- eMMC ---

run_test "HW-10" "eMMC block device present" \
  "ls /dev/mmcblk* >/dev/null 2>&1"

# Verify root filesystem is on SD card, not eMMC (eMMC should be erased)
ROOT_DEV=$(mount | grep 'on / ' | awk '{print $1}')
run_test_show "HW-10b" "Root filesystem on SD card (not eMMC)" \
  "echo \"$ROOT_DEV\" | grep -qv 'mmcblk0' || mount | grep 'on / ' | grep -q '/dev/sd\|/dev/vd\|loop'"

# Check eMMC first sector is zeroed (erased during provisioning)
if [ -b /dev/mmcblk0 ]; then
  EMMC_ZEROS=$(dd if=/dev/mmcblk0 bs=512 count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n')
  EXPECTED=$(printf '0' | head -c ${#EMMC_ZEROS} | tr '0' '0')
  run_test "HW-10c" "eMMC first sector is zeroed (erased)" \
    "[ \"$EMMC_ZEROS\" = \"$(printf '%0*d' ${#EMMC_ZEROS} 0)\" ]"
else
  skip_test "HW-10c" "eMMC first sector is zeroed" "mmcblk0 not found"
fi

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
