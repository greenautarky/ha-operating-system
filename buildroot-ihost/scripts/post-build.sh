#!/bin/bash
# iHost board post-build: runs after upstream HAOS's and the GA layer's
# (BR2_ROOTFS_POST_BUILD_SCRIPT order). $1 = TARGET_DIR, $2 = board dir.

set -e

TARGET_DIR=${1:?TARGET_DIR missing}
BOARD_DIR=${2:?board dir missing (BR2_ROOTFS_POST_SCRIPT_ARGS)}
. "${BOARD_DIR}/meta"

function gadget_console() {
    mkdir -p "${TARGET_DIR}/etc/systemd/system/getty.target.wants"
    ln -fs "/usr/lib/systemd/system/serial-getty@.service" "${TARGET_DIR}/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service"
}

if [ "${BOARD_ID}" == "ihost" ]; then
    gadget_console
fi

# The board's build-input hooks (root password, OpenStick key), from
# this board's own directory — not from an absolute path inside one particular
# build container. (The hooks every board runs: Wi-Fi install PSK, SSH certificate plane and
# NetBird setup key, are in the GA layer: buildroot-external/scripts/post-build.d/.) A hook that
# is not executable fails the build: skipping it would ship an image without
# what the hook installs, and nothing else would notice.
shopt -s nullglob
for s in "${BOARD_DIR}"/post-build.d/*.sh; do
    [ -x "$s" ] || { echo "ihost post-build: FAIL: $s is not executable" >&2; exit 1; }
    echo "ihost post-build: running $(basename "$s")"
    "$s" "${TARGET_DIR}"
done
