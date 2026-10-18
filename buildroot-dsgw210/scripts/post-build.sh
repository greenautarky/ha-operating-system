#!/bin/bash
# DSGW-210 board post-build (after the HAOS and the GA_HAOS ones).
# Same runner as buildroot-ihost/scripts/post-build.sh: runs the board's own
# post-build.d hooks from its own dir. $1 = TARGET_DIR, $2 = board dir
# (BR2_ROOTFS_POST_SCRIPT_ARGS). First hook: 80-root-password.sh (ADR-0039
# start password, the iHost mechanism).
set -e
TARGET_DIR=${1:?TARGET_DIR missing}
BOARD_DIR=${2:?board dir missing (BR2_ROOTFS_POST_SCRIPT_ARGS)}
shopt -s nullglob
for s in "${BOARD_DIR}"/post-build.d/*.sh; do
    [ -x "$s" ] || { echo "dsgw210 post-build: FAIL: $s is not executable" >&2; exit 1; }
    echo "dsgw210 post-build: running $(basename "$s")"
    "$s" "${TARGET_DIR}"
done
