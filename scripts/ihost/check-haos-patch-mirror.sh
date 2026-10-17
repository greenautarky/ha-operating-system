#!/bin/bash
# The iHost stays on U-Boot 2024.01, but HAOS 18.x rebased its global U-Boot
# patch (fileenv) onto 2026.04 and it no longer applies. Buildroot applies
# every global patch dir per package with no way to exclude one, so the iHost
# defconfig does NOT list $(BR2_EXTERNAL_HAOS_PATH)/patches. It lists
# buildroot-ihost/patches-haos/ instead: one symlink per HAOS package dir, and
# a real uboot/ dir holding the 2024.01 rebase of the same patch (carried from
# ha-operating-system 43cdc2283, where it builds the fielded iHost).
#
# This check keeps the mirror honest on every configure (fails, never skips):
#   * every package dir HAOS has must be mirrored (a new upstream patch dir
#     would otherwise silently not reach the iHost build);
#   * every symlink must resolve into haos/buildroot-external/patches;
#   * HAOS's uboot/ dir must still hold exactly the one patch we replace.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
UP="$REPO/haos/buildroot-external/patches"
MIR="$REPO/buildroot-ihost/patches-haos"
fail() { echo "check-haos-patch-mirror: FAIL: $*" >&2; exit 1; }
[ -d "$UP" ] || fail "$UP missing"
n=0
for d in "$UP"/*/; do
    p=$(basename "$d"); n=$((n+1))
    if [ "$p" = uboot ]; then
        [ -d "$MIR/uboot" ] && [ ! -L "$MIR/uboot" ] || fail "uboot/ must be a real dir in $MIR"
        up=$(cd "$UP/uboot" && ls)
        [ "$up" = "0001-CMD-read-string-from-fileinto-env.patch" ] \
            || fail "HAOS patches/uboot changed (now: $(echo $up)); re-check what the iHost 2024.01 replacement must carry"
        continue
    fi
    [ -L "$MIR/$p" ] || fail "HAOS patch dir '$p' is not mirrored in $MIR"
    [ "$(readlink -f "$MIR/$p")" = "$(readlink -f "$d")" ] || fail "$MIR/$p does not point at $d"
done
for m in "$MIR"/*; do
    [ -e "$UP/$(basename "$m")" ] || fail "$m mirrors a HAOS patch dir that no longer exists"
done
[ "$n" -gt 0 ] || fail "found zero HAOS patch dirs"
echo "check-haos-patch-mirror: OK ($n HAOS patch dirs, uboot replaced by the 2024.01 rebase)"
