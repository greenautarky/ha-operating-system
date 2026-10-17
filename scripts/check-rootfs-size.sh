#!/usr/bin/env bash
# check-rootfs-size.sh — the rootfs image must fit the smallest system slot it
# can be installed into, with a margin.
#
# Usage: scripts/check-rootfs-size.sh <images dir>     (Buildroot $O/images)
#
# WHY
#   A fresh HAOS 18.x image has 256 MiB system slots (hdd-image.sh SYSTEM_SIZE).
#   A device flashed with an earlier GA image keeps its larger slots across an
#   OTA, so one bundle must fit both — the smaller one decides. A rootfs that
#   outgrows the slot does not fail the build: genimage or RAUC refuses it on
#   the device, at install time. The margin keeps the next release from finding
#   out that way.
#
# The limit is a PINNED constant (rule: an audit never reads its expected value
# from the artefact it audits). Raise it only together with the slot layout.
#
# Exactly one rootfs image (rootfs.erofs, rootfs.squashfs) must be found; zero
# is a failure, never a pass. Exit: 0 fits · 1 too big · 2 cannot check.
set -uo pipefail

SLOT_BYTES=$((256 * 1024 * 1024))       # HAOS 18.x system slot (SYSTEM_SIZE=256M)
MARGIN_PCT=10
LIMIT_BYTES=$((SLOT_BYTES * (100 - MARGIN_PCT) / 100))

dir="${1:?usage: $0 <images dir>}"
[ -d "$dir" ] || { echo "rootfs-size: ERROR: $dir is not a directory" >&2; exit 2; }
imgs=()
for f in "$dir"/rootfs.erofs "$dir"/rootfs.squashfs; do
  [ -e "$f" ] && imgs+=("$f")
done
if [ "${#imgs[@]}" -ne 1 ]; then
  echo "rootfs-size: ERROR: expected exactly one rootfs image in $dir, found ${#imgs[@]}${imgs[*]:+: ${imgs[*]}}" >&2
  exit 2
fi
img="${imgs[0]}"
size="$(stat -L -c %s "$img" 2>/dev/null)" || { echo "rootfs-size: ERROR: cannot stat $img" >&2; exit 2; }
mib() { awk -v b="$1" 'BEGIN { printf "%.1f MiB", b / 1048576 }'; }
if [ "$size" -gt "$LIMIT_BYTES" ]; then
  echo "rootfs-size: FAIL: $(basename "$img") is $(mib "$size"), limit $(mib "$LIMIT_BYTES") (256 MiB slot - ${MARGIN_PCT} %)" >&2
  exit 1
fi
echo "rootfs-size: OK: $(basename "$img") $(mib "$size") <= $(mib "$LIMIT_BYTES") (256 MiB slot - ${MARGIN_PCT} %), headroom $(mib $((SLOT_BYTES - size))) to the slot"
