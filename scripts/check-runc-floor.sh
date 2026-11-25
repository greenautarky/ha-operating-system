#!/usr/bin/env bash
# The EFFECTIVE runc is at or above the pinned minimum, from our package dir, with a hash for it and
# HAOS's six device patches in the state they were rebased from.
#   check-runc-floor.sh [EXT_DIR] [BUILDROOT_DIR] [LOCAL_MK...]
# Exit 0 ok, 1 finding, 2 could not judge. Self-test: tests/gates/runc_floor/selftest.sh.
set -uo pipefail

MIN_RUNC=1.4.4
# sha256 of the submodule's package/runc/*.patch that runc-floor/ was rebased from. PINNED: change only
# after re-checking the rebase.
UPSTREAM_PATCHES="0001-Separate-Device-handling-for-default-AllowDevices.patch=8459c76f65312493 0002-Implement-common-function-to-create-DeviceCgroup-rul.patch=e4ce38af656b522d 0003-Implement-Device-Resources-updates.patch=9af8d2fed1bd9f84 0004-Add-integration-tests-for-device-updates.patch=963d025d570c78db 0005-Incremental-update-device-permission.patch=275dc301163dbb8d 0006-Add-IsDefault-flag-for-dev-net-tun-entry.patch=96d1a8ffd6eb4761"
# runc-floor/ must hold exactly these bytes.
GA_PATCHES="0001-Separate-Device-handling-for-default-AllowDevices.patch=facc4afa77513c11 0002-Implement-common-function-to-create-DeviceCgroup-rul.patch=e4ce38af656b522d 0003-Implement-Device-Resources-updates.patch=9af8d2fed1bd9f84 0004-Add-integration-tests-for-device-updates.patch=963d025d570c78db 0005-Incremental-update-device-permission.patch=275dc301163dbb8d 0006-Add-IsDefault-flag-for-dev-net-tun-entry.patch=96d1a8ffd6eb4761"

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
# shellcheck source=lib/tree-paths.sh
. "$here/lib/tree-paths.sh"
ext="${1:-$repo/$GA_LAYER_DIR}"
br="${2:-$repo/$GA_HAOS_DIR/buildroot}"
mk="$ext/runc-floor.mk"
shift 2 2>/dev/null || shift $#
localmks=("$@")
if [ "${#localmks[@]}" -eq 0 ]; then
  for b in $GA_BOARDS; do localmks+=("$repo/$(ga_board_var BOARD_DIR "$b")/local.mk"); done
fi
die() { echo "runc-floor: ERROR: $*" >&2; exit 2; }
fail=0
bad() { echo "runc-floor: FAIL: $*" >&2; fail=1; }
sums() { (cd "$1" 2>/dev/null && sha256sum ./*.patch 2>/dev/null | awk '{sub(/^\.\//,"",$2); print $2"="substr($1,1,16)}' | tr '\n' ' ' | sed 's/ $//'); }

[ -f "$mk" ] || die "$mk not found"
pmk="$br/package/runc/runc.mk"
[ -f "$pmk" ] || die "$pmk not found (is the haos submodule checked out?)"
command -v make >/dev/null || die "make not found"
for lm in "${localmks[@]}"; do
  [ -f "$lm" ] || die "$lm not found"
  grep -qE '^include[[:space:]].*runc-floor\.mk' "$lm" || bad "$lm does not include runc-floor.mk (the floor would never apply)"
done
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
grep -E "^RUNC_VERSION[[:space:]]*=" "$pmk" >"$tmp/runc.mk" || die "no RUNC_VERSION in $pmk"
cat >"$tmp/Makefile" <<MAKE
TOPDIR = $br
include $mk
include $tmp/runc.mk
RUNC_PKGDIR = $br/package/runc/
HOST_RUNC_PKGDIR = $br/package/runc/
\$(info EFFECTIVE=\$(RUNC_VERSION))
\$(info PKGDIR=\$(RUNC_PKGDIR))
\$(info HOSTPKGDIR=\$(HOST_RUNC_PKGDIR))
all: ;
MAKE
out="$(make -s -f "$tmp/Makefile" 2>&1)" || die "make failed: $out"
eff="$(sed -n 's/^EFFECTIVE=//p' <<<"$out" | head -n 1)"
pkgdir="$(sed -n 's/^PKGDIR=//p' <<<"$out" | head -n 1)"
hostdir="$(sed -n 's/^HOSTPKGDIR=//p' <<<"$out" | head -n 1)"
[ -n "$eff" ] || die "no effective version: $out"
[ "$(printf '%s\n%s\n' "$MIN_RUNC" "$eff" | sort -V | head -n 1)" = "$MIN_RUNC" ] \
  || bad "runc effective version $eff is below the pinned minimum $MIN_RUNC"
re="^sha256[[:space:]]+[0-9a-f]{64}[[:space:]]+runc-${eff//./\\.}-go2\\.tar\\.gz\$"
[ "$hostdir" = "$pkgdir" ] || bad "HOST_RUNC_PKGDIR ($hostdir) differs from RUNC_PKGDIR ($pkgdir)"
grep -qE "$re" "${pkgdir%/}/runc.hash" 2>/dev/null || bad "runc $eff: no sha256 entry for runc-$eff-go2.tar.gz in ${pkgdir%/}/runc.hash"
if [ "$pkgdir" = "$br/package/runc/" ]; then
  [ "$fail" -ne 0 ] || echo "runc-floor: the submodule carries runc $eff itself (the GA carry is obsolete)"
else
  grep -qE "^sha256[[:space:]]+[0-9a-f]{64}[[:space:]]+LICENSE\$" "${pkgdir%/}/runc.hash" 2>/dev/null || bad "no sha256 entry for LICENSE"
  [ "$(sums "$br/package/runc")" = "$UPSTREAM_PATCHES" ] || bad "the submodule's package/runc patches changed ($(sums "$br/package/runc")); re-check the rebase in runc-floor/"
  [ "$(sums "$pkgdir")" = "$GA_PATCHES" ] || bad "runc-floor/ does not hold the six pinned patches ($(sums "$pkgdir"))"
fi
[ "$fail" -eq 0 ] && echo "runc-floor: OK (effective runc $eff, ${#localmks[@]} local.mk inspected)"
exit "$fail"
