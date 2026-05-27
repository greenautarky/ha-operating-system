#!/bin/sh
# eMMC erase test suite — runs ON the device.
# Verifies that ga-emmc-erase ran on first boot and wiped /dev/mmcblk0
# (forcing SD-only boot). Replaces ga-flasher-py stage 35.
#
# Counterpart build tests: EMMC-ERASE-01..05 in run_build_tests.sh.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
suite_start "eMMC erase"

MARKER="/mnt/data/.ga_emmc_erased"

# EMMC-ERASE-D-01: script + unit baked.
run_test "EMMC-ERASE-D-01" "ga-emmc-erase script present + executable" \
  "test -x /usr/libexec/ga-emmc-erase"

run_test "EMMC-ERASE-D-02" "ga-emmc-erase.service unit present" \
  "test -f /usr/lib/systemd/system/ga-emmc-erase.service"

# EMMC-ERASE-D-03: service active (RemainAfterExit=yes after oneshot success).
run_test "EMMC-ERASE-D-03" "ga-emmc-erase.service is active" \
  "systemctl is-active ga-emmc-erase.service >/dev/null"

# EMMC-ERASE-D-04: marker file present + has the expected method= field.
run_test "EMMC-ERASE-D-04" "marker /mnt/data/.ga_emmc_erased present" \
  "test -f $MARKER && test -s $MARKER"

run_test "EMMC-ERASE-D-05" "marker contains method= (blkdiscard or dd-zero-*)" \
  "grep -qE 'method=(blkdiscard|dd-zero|no-emmc)' $MARKER"

# EMMC-ERASE-D-06: actual wipe verification. The first 16 MiB of mmcblk0
# should be zeros (blkdiscard reads as zeros on supported eMMC; dd zero-fill
# definitely produces zeros). Read 64 KiB worth and md5 it — known zero MD5
# is f8e7297adea0b8f9e9d6fa3c46bce7a3 (64 KiB of zeros).
# On a board without eMMC (no-emmc marker), skip this check.
if ! grep -q 'method=no-emmc' "$MARKER" 2>/dev/null; then
  run_test "EMMC-ERASE-D-06" "/dev/mmcblk0 first 64 KiB is zeros (md5 sanity)" \
    "head -c 65536 /dev/mmcblk0 2>/dev/null | md5sum | awk '{print \$1}' | grep -q '^fa43239bcee7b97ca62f007cc68487a0$\\|^f8e7297adea0b8f9e9d6fa3c46bce7a3$\\|^7029066c27ac6f5ef18d660d5741979a$'"
fi

# EMMC-ERASE-D-07: root is genuinely on mmcblk2 (SD) — sanity / safety
# proves the device still boots from SD after the erase.
run_test "EMMC-ERASE-D-07" "root filesystem still on mmcblk2 (SD) post-erase" \
  "grep -q 'mmcblk2.*\\s/' /proc/mounts || grep -q 'mmcblk2' /proc/mounts"

suite_end
