#!/bin/bash
# The iHost stays on U-Boot 2024.01, but HAOS 18.x rebased its global U-Boot
# patch (fileenv) onto 2026.04 and it no longer applies. Buildroot applies
# every global patch dir per package with no way to exclude one, so the iHost
# defconfig does NOT list $(BR2_EXTERNAL_HAOS_PATH)/patches. It lists
# buildroot-ihost/patches-haos/ instead: one symlink per HAOS package dir, and
# a real uboot/ dir holding the 2024.01 rebase of the same patch (carried from
# ha-operating-system 43cdc2283, where it builds the fielded iHost).
#
# docker-engine/ is a second real dir: the GA container floor
# (buildroot-external/container-floor.mk) builds docker-engine 29.8.2, and
# HAOS 18.3's bridge-subnet patch for 29.7.2 no longer applies there (second
# hunk of iptabler/network.go moved; buildroot applies patches with no fuzz).
# The dir holds the same patch rebased onto 29.8.2. Drop it, and make the dir a
# symlink again, once HAOS ships a patch that applies to the docker-engine
# version the floor resolves to.
#
# This check keeps the mirror honest on every configure (fails, never skips):
#   * every package dir HAOS has must be mirrored (a new upstream patch dir
#     would otherwise silently not reach the iHost build);
#   * every symlink must resolve into haos/buildroot-external/patches;
#   * HAOS's uboot/ and docker-engine/ dirs must still hold exactly the one
#     patch we replace (docker-engine: byte-identical to the one we rebased,
#     sha256 pinned below), so an upstream change forces a re-check;
#   * the replacement dirs are real dirs holding exactly one patch.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
UP="$REPO/haos/buildroot-external/patches"
MIR="$REPO/buildroot-ihost/patches-haos"
# sha256 of HAOS 18.3's docker-engine/0001 (bridge-subnet protection, written
# for docker-engine 29.7.2) that buildroot-ihost/patches-haos/docker-engine/0001
# is the rebase of. PINNED: change it only after re-checking the rebase.
DOCKER_UP_PATCH=0001-bridge-protect-bridge-subnet-from-direct-external-ac.patch
DOCKER_UP_SHA=5e6179c245dbcefc351374e32177b7519cc2105c056ea2940325d389e73fb224
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
    if [ "$p" = docker-engine ]; then
        [ -d "$MIR/docker-engine" ] && [ ! -L "$MIR/docker-engine" ] || fail "docker-engine/ must be a real dir in $MIR"
        up=$(cd "$UP/docker-engine" && ls)
        [ "$up" = "$DOCKER_UP_PATCH" ] \
            || fail "HAOS patches/docker-engine changed (now: $(echo $up)); re-check what the 29.8.2 replacement must carry"
        [ "$(sha256sum "$UP/docker-engine/$DOCKER_UP_PATCH" | cut -d' ' -f1)" = "$DOCKER_UP_SHA" ] \
            || fail "HAOS patches/docker-engine/$DOCKER_UP_PATCH changed upstream; re-check the 29.8.2 rebase, then update DOCKER_UP_SHA"
        [ "$(ls "$MIR/docker-engine" | wc -l)" = 1 ] && [ -f "$MIR/docker-engine/$DOCKER_UP_PATCH" ] && [ ! -L "$MIR/docker-engine/$DOCKER_UP_PATCH" ] \
            || fail "$MIR/docker-engine must hold exactly the rebased $DOCKER_UP_PATCH as a regular file"
        continue
    fi
    [ -L "$MIR/$p" ] || fail "HAOS patch dir '$p' is not mirrored in $MIR"
    [ "$(readlink -f "$MIR/$p")" = "$(readlink -f "$d")" ] || fail "$MIR/$p does not point at $d"
done
for m in "$MIR"/*; do
    [ -e "$UP/$(basename "$m")" ] || fail "$m mirrors a HAOS patch dir that no longer exists"
done
[ "$n" -gt 0 ] || fail "found zero HAOS patch dirs"
echo "check-haos-patch-mirror: OK ($n HAOS patch dirs, uboot replaced by the 2024.01 rebase, docker-engine by the 29.8.2 rebase)"
