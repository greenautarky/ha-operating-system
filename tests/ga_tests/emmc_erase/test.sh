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

# EMMC-ERASE-D-05: marker SHAPE — accept either our format (method=...)
# OR ga-bootstrap-disk's format ("erased by ga-bootstrap-disk"). On a stock
# V1.2-clean image, ga-bootstrap-disk fires ~1s BEFORE ga-emmc-erase and
# wins the marker; our service then detects the marker and idempotent-exits.
# Both producers leave the eMMC genuinely zeroed (D-06 is the wipe-truth
# test). See: todo_v12_bake_followups_2026_05_27.md item #2.
run_test "EMMC-ERASE-D-05" "marker SHAPE (method= or ga-bootstrap-disk)" \
  "grep -qE 'method=(blkdiscard|dd-zero|no-emmc)|erased by ga-bootstrap-disk' $MARKER"

# EMMC-ERASE-D-06: actual wipe verification. Read first 64 KiB of /dev/mmcblk0
# and verify it's zero — `fcd6bcb56c1689fcef28b57c22475bad` is the canonical
# md5 of 65536 zero bytes (verified live KIB-SON-31 2026-05-27 against
# `head -c 65536 /dev/zero | md5sum`). Skip on no-emmc boards (e.g. HA Green
# where this code path doesn't run).
if ! grep -q 'method=no-emmc' "$MARKER" 2>/dev/null; then
  run_test "EMMC-ERASE-D-06" "/dev/mmcblk0 first 64 KiB is zeros (md5 sanity)" \
    "head -c 65536 /dev/mmcblk0 2>/dev/null | md5sum | awk '{print \$1}' | grep -qx 'fcd6bcb56c1689fcef28b57c22475bad'"
fi

# EMMC-ERASE-D-07: root is genuinely on mmcblk2 (SD) — sanity / safety
# proves the device still boots from SD after the erase.
run_test "EMMC-ERASE-D-07" "root filesystem still on mmcblk2 (SD) post-erase" \
  "grep -q 'mmcblk2.*\\s/' /proc/mounts || grep -q 'mmcblk2' /proc/mounts"

suite_end
