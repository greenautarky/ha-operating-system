#!/bin/bash
# The DSGW-210 board lists buildroot-dsgw210/patches-haos/ as its global patch
# dir instead of HAOS's own patches/ dir, for one reason: the GA container floor
# (buildroot-external/container-floor.mk) builds docker-engine 29.8.2, and
# HAOS 18.3's bridge-subnet patch for 29.7.2 does not apply to it (buildroot
# applies patches with no fuzz). The iHost board already carries that patch
# rebased onto 29.8.2 (buildroot-ihost/patches-haos/docker-engine/); this board
# points at the same directory so there is one copy to maintain. Every other
# HAOS patch dir is mirrored as a symlink. U-Boot is 2026.04 here, the version
# HAOS's own uboot patch is written for, so uboot/ is a plain symlink (the
# iHost stays on 2024.01 and carries a rebase).
#
# This check keeps the mirror honest on every configure (fails, never skips):
#   * every package dir HAOS has must be mirrored (a new upstream patch dir
#     would otherwise silently not reach this board's build);
#   * every symlink must resolve into haos/buildroot-external/patches, except
#     docker-engine, which must resolve to the iHost board's real dir;
#   * that real dir must still be the one rebased patch
#     (scripts/ihost/check-haos-patch-mirror.sh holds it against HAOS's);
#   * nothing in the mirror may be a package dir HAOS no longer has.
set -euo pipefail
shopt -s nullglob
REPO=$(cd "$(dirname "$0")/../.." && pwd)
UP="$REPO/haos/buildroot-external/patches"
MIR="$REPO/buildroot-dsgw210/patches-haos"
IHOST_DE="$REPO/buildroot-ihost/patches-haos/docker-engine"
fail() { echo "check-dsgw210-haos-patch-mirror: FAIL: $*" >&2; exit 1; }
[ -d "$UP" ] || fail "$UP missing"
[ -d "$MIR" ] || fail "$MIR missing"
[ -d "$IHOST_DE" ] && [ ! -L "$IHOST_DE" ] || fail "$IHOST_DE must be a real dir (the rebased docker-engine patch)"
[ "$(ls "$IHOST_DE" | wc -l)" = 1 ] || fail "$IHOST_DE must hold exactly one patch"
n=0
for d in "$UP"/*/; do
    p=$(basename "$d"); n=$((n+1))
    [ -L "$MIR/$p" ] || fail "HAOS patch dir '$p' is not mirrored in $MIR"
    if [ "$p" = docker-engine ]; then
        [ "$(readlink -f "$MIR/$p")" = "$(readlink -f "$IHOST_DE")" ] \
            || fail "$MIR/docker-engine must resolve to $IHOST_DE (the 29.8.2 rebase), not to HAOS's 29.7.2 patch"
        continue
    fi
    [ "$(readlink -f "$MIR/$p")" = "$(readlink -f "$d")" ] || fail "$MIR/$p does not point at $d"
done
for m in "$MIR"/*; do
    [ -e "$UP/$(basename "$m")" ] || fail "$m mirrors a HAOS patch dir that no longer exists"
done
[ "$n" -gt 0 ] || fail "found zero HAOS patch dirs"
echo "check-dsgw210-haos-patch-mirror: OK ($n HAOS patch dirs mirrored, docker-engine = the shared 29.8.2 rebase)"
