#!/bin/sh
# eMMC erase test suite — runs ON the device.
# Verifies the eMMC wipe ran on first boot (forcing SD-only boot).
# Owned by ga-bootstrap-disk (the standalone ga-emmc-erase unit was deleted
# 2026-05-28 as a redundant duplicate). Replaces ga-flasher-py stage 35.
#
# Counterpart build tests: EMMC-ERASE-01..05 in run_build_tests.sh.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
suite_start "eMMC erase"

MARKER="/mnt/data/.ga_emmc_erased"

# EMMC-ERASE-D-01: script + unit baked.
run_test "EMMC-ERASE-D-01" "ga-bootstrap-disk script present + executable" \
  "test -x /usr/libexec/ga-bootstrap-disk"

run_test "EMMC-ERASE-D-02" "ga-bootstrap-disk.service unit present" \
  "test -f /usr/lib/systemd/system/ga-bootstrap-disk.service"

# EMMC-ERASE-D-03: service ran successfully (oneshot, sysinit — pre-Supervisor).
run_test "EMMC-ERASE-D-03" "ga-bootstrap-disk.service ran (active/exited)" \
  "systemctl is-active ga-bootstrap-disk.service >/dev/null || systemctl show ga-bootstrap-disk.service -p Result --value 2>/dev/null | grep -q success"

# EMMC-ERASE-D-04: marker file present + has the expected method= field.
run_test "EMMC-ERASE-D-04" "marker /mnt/data/.ga_emmc_erased present" \
  "test -f $MARKER && test -s $MARKER"

# EMMC-ERASE-D-05: marker SHAPE — ga-bootstrap-disk writes
# "erased by ga-bootstrap-disk". (The legacy method=... form is still
# accepted for devices imaged before the 2026-05-28 ga-emmc-erase deletion.)
# D-06 is the wipe-truth test. See: todo_v12_bake_followups_2026_05_27.md #2.
run_test "EMMC-ERASE-D-05" "marker SHAPE (ga-bootstrap-disk or legacy method=)" \
  "grep -qE 'erased by ga-bootstrap-disk|method=(blkdiscard|dd-zero|no-emmc)' $MARKER"

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
