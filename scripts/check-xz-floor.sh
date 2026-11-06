#!/usr/bin/env bash
# check-xz-floor.sh — the xz in the image is at or above the pinned minimum, and
# the GA carry that lifts it is complete.
#
# Usage: scripts/check-xz-floor.sh [EXTERNAL_DIR] [BUILDROOT_DIR] [LOCAL_MK...]
#        defaults: the GA layer (tree-paths.sh), <haos>/buildroot and the
#        local.mk of every board in GA_BOARDS (each must include the floor file)
#
# WHY
#   The buildroot submodule pins xz 5.6.4, which sits inside three published
#   advisories fixed in 5.8.4. buildroot-external/xz-floor.mk lifts it (override
#   before package/*/*.mk, same mechanism as go-floor.mk) and points the package
#   dir at xz-floor/ so the submodule's own patches (already inside 5.8.4) are
#   not applied. Ways it rots silently: the floor line is edited down, the hash
#   file names another version (the build then fails late), the PKGDIR redirect
#   is lost (patches then fail to apply), or the override stops taking effect.
#   The effective values are EVALUATED with make exactly as the build does
#   (floor file first, then the package's own plain assignments).
#
# MIN_XZ is a PINNED constant (an audit never reads its expected value from the
# artefact it audits). Raise it with a security bump.
#
# Exit: 0 all hold · 1 a check failed · 2 cannot check (never a pass).
set -uo pipefail

MIN_XZ=5.8.4

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
# shellcheck source=lib/tree-paths.sh
. "$here/lib/tree-paths.sh"
ext="${1:-$repo/$GA_LAYER_DIR}"
br="${2:-$repo/$GA_HAOS_DIR/buildroot}"
mk="$ext/xz-floor.mk"
shift 2 2>/dev/null || shift $#
localmks=("$@")
if [ "${#localmks[@]}" -eq 0 ]; then
  for b in $GA_BOARDS; do localmks+=("$repo/$(ga_board_var BOARD_DIR "$b")/local.mk"); done
fi

die() { echo "xz-floor: ERROR: $*" >&2; exit 2; }
fail=0
bad() { echo "xz-floor: FAIL: $*" >&2; fail=1; }

[ -f "$mk" ] || die "$mk not found"
pmk="$br/package/xz/xz.mk"
[ -f "$pmk" ] || die "$pmk not found (is the haos submodule checked out?)"
command -v make >/dev/null || die "make not found"

n=0
for lm in "${localmks[@]}"; do
  [ -f "$lm" ] || die "$lm not found"
  n=$((n + 1))
  if grep -qE '^include[[:space:]].*xz-floor\.mk' "$lm"; then
    echo "xz-floor: ok   $lm includes xz-floor.mk"
  else
    bad "$lm does not include xz-floor.mk (the floor would never apply)"
  fi
done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# The package's own plain assignments, evaluated AFTER the floor file.
grep -E "^XZ_VERSION[[:space:]]*=" "$pmk" >"$tmp/xz.mk" || die "no XZ_VERSION in $pmk"
cat >"$tmp/Makefile" <<MAKE
TOPDIR = $br
include $mk
include $tmp/xz.mk
XZ_PKGDIR = $br/package/xz/
HOST_XZ_PKGDIR = $br/package/xz/
\$(info EFFECTIVE=\$(XZ_VERSION))
\$(info PKGDIR=\$(XZ_PKGDIR))
\$(info HOSTPKGDIR=\$(HOST_XZ_PKGDIR))
all: ;
MAKE
out="$(make -s -f "$tmp/Makefile" 2>&1)" || die "make failed: $out"
eff="$(sed -n 's/^EFFECTIVE=//p' <<<"$out" | head -n 1)"
pkgdir="$(sed -n 's/^PKGDIR=//p' <<<"$out" | head -n 1)"
hostdir="$(sed -n 's/^HOSTPKGDIR=//p' <<<"$out" | head -n 1)"
[ -n "$eff" ] || die "no effective version: $out"
if [ "$(printf '%s\n%s\n' "$MIN_XZ" "$eff" | sort -V | head -n 1)" != "$MIN_XZ" ]; then
  bad "xz effective version $eff is below the pinned minimum $MIN_XZ"
  [ "$fail" -eq 0 ] || exit 1
fi

tarball="xz-$eff.tar.bz2"
re="^sha256[[:space:]]+[0-9a-f]{64}[[:space:]]+${tarball//./\\.}\$"
if [ "$pkgdir" = "$br/package/xz/" ]; then
  # Floor off: the submodule is at/above the minimum and carries its own files.
  if grep -qE "$re" "$br/package/xz/xz.hash" 2>/dev/null; then
    echo "xz-floor: ok   xz $eff (>= $MIN_XZ), submodule's own hash entry (the GA carry is obsolete)"
  else
    bad "xz $eff: no sha256 entry for $tarball in the submodule's xz.hash"
  fi
else
  [ "$hostdir" = "$pkgdir" ] || bad "HOST_XZ_PKGDIR ($hostdir) differs from XZ_PKGDIR ($pkgdir)"
  gahash="${pkgdir%/}/xz.hash"
  if grep -qE "$re" "$gahash" 2>/dev/null; then
    echo "xz-floor: ok   xz $eff (>= $MIN_XZ), GA hash entry for $tarball in $gahash"
  else
    bad "xz $eff: no sha256 entry for $tarball in $gahash"
  fi
  for f in COPYING COPYING.0BSD COPYING.GPLv2 COPYING.GPLv3 COPYING.LGPLv2.1; do
    grep -qE "^sha256[[:space:]]+[0-9a-f]{64}[[:space:]]+${f//./\\.}\$" "$gahash" 2>/dev/null \
      || bad "xz $eff: no sha256 entry for licence file $f in $gahash"
  done
  if compgen -G "${pkgdir%/}/*.patch" >/dev/null; then
    bad "${pkgdir%/} holds patches; they were written for another xz version (use patches/xz only for a version-matched fix)"
  fi
fi
[ "$n" -ge 1 ] || die "inspected no local.mk"
[ "$fail" -eq 0 ] && echo "xz-floor: OK (effective xz $eff, $n local.mk inspected)"
exit "$fail"
