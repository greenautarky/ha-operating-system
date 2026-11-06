#!/usr/bin/env bash
# check-container-floor.sh — containerd in the
# image is at or above the pinned minimum, and the GA carry that lifts them
# is complete.
#
# Usage: scripts/check-container-floor.sh [EXTERNAL_DIR] [BUILDROOT_DIR] [LOCAL_MK...]
#        defaults: buildroot-external, ./buildroot and buildroot-ihost/local.mk
#
# WHY
#   The buildroot submodule pins containerd 2.3.6, which sits inside four
#   published advisories fixed in 2.3.7 (GHSA-5p7c-hggf-c748, GHSA-8647-2jxj-p2rc,
#   GHSA-hc94-p972-ch66, GHSA-vwhp-8p66-mq4f). buildroot-external/container-floor.mk
#   lifts it (override before package/*/*.mk, same mechanism as go-floor.mk and
#   xz-floor.mk), with the tarball hash in patches/containerd/containerd.hash.
#   Three ways it rots silently: the floor line is edited down, the hash file is
#   missing or names another version (the build then fails late, or a stale hash
#   lingers), or the override stops taking effect and the image keeps the old
#   runtime. The effective version is therefore EVALUATED with make exactly as
#   the build does (floor file first, then the package's own plain assignment),
#   not read back from the floor file.
#
# MIN_CONTAINERD below is a PINNED constant (an audit never reads its expected value from
# the artefact it audits). Raise them with a security bump.
#
# Exit: 0 all hold · 1 a check failed · 2 cannot check (never a pass).
set -uo pipefail

MIN_CONTAINERD=2.3.7

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
ext="${1:-$repo/buildroot-external}"
br="${2:-$repo/buildroot}"
mk="$ext/container-floor.mk"
shift 2 2>/dev/null || shift $#
localmks=("$@")
[ "${#localmks[@]}" -gt 0 ] || localmks=("$repo/buildroot-ihost/local.mk")

die() { echo "container-floor: ERROR: $*" >&2; exit 2; }
fail=0
bad() { echo "container-floor: FAIL: $*" >&2; fail=1; }

[ -f "$mk" ] || die "$mk not found"
[ -d "$br/package" ] || die "$br/package not found (is the buildroot submodule checked out?)"
command -v make >/dev/null || die "make not found"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
for lm in "${localmks[@]}"; do
  [ -f "$lm" ] || die "$lm not found"
  # An include that is commented out or missing means the floor never applies.
  if grep -qE '^include[[:space:]].*container-floor\.mk' "$lm"; then
    echo "container-floor: ok   $lm includes container-floor.mk"
  else
    bad "$lm does not include container-floor.mk (the floor would never apply)"
  fi
done
n=0
for spec in CONTAINERD:containerd:$MIN_CONTAINERD; do
  IFS=: read -r pfx pkg min <<<"$spec"
  pmk="$br/package/$pkg/$pkg.mk"
  [ -f "$pmk" ] || die "$pmk not found"
  # The package's own plain version assignment, evaluated AFTER the floor file.
  grep -E "^${pfx}_VERSION[[:space:]]*=" "$pmk" >"$tmp/$pkg.mk" || die "no ${pfx}_VERSION in $pmk"
  cat >"$tmp/Makefile" <<MAKE
TOPDIR = $br
include $mk
include $tmp/$pkg.mk
\$(info EFFECTIVE=\$(${pfx}_VERSION))
all: ;
MAKE
  out="$(make -s -f "$tmp/Makefile" 2>&1)" || die "make failed for $pkg: $out"
  eff="$(sed -n 's/^EFFECTIVE=//p' <<<"$out" | head -n 1)"
  [ -n "$eff" ] || die "no effective version for $pkg: $out"
  n=$((n + 1))
  if [ "$(printf '%s\n%s\n' "$min" "$eff" | sort -V | head -n 1)" != "$min" ]; then
    bad "$pkg effective version $eff is below the pinned minimum $min"
    continue
  fi
  # The hash for the effective version must be reachable: either a GA hash
  # file naming it, or (submodule already at/above the floor) buildroot's own.
  tarball="$pkg-$eff-go2.tar.gz"
  gahash="$ext/patches/$pkg/$pkg.hash"
  if grep -qE "^sha256[[:space:]]+[0-9a-f]{64}[[:space:]]+${tarball//./\\.}\$" "$gahash" 2>/dev/null; then
    echo "container-floor: ok   $pkg $eff (>= $min), GA hash entry for $tarball"
  elif grep -qE "^sha256[[:space:]]+[0-9a-f]{64}[[:space:]]+${tarball//./\\.}\$" "$br/package/$pkg/$pkg.hash" 2>/dev/null; then
    echo "container-floor: ok   $pkg $eff (>= $min), submodule's own hash entry (the GA carry is obsolete)"
  else
    bad "$pkg $eff: no sha256 entry for $tarball in $gahash or the submodule's $pkg.hash"
  fi
done
[ "$n" -eq 1 ] || die "inspected $n packages, expected 1"
[ "$fail" -eq 0 ] && echo "container-floor: OK ($n package inspected)"
exit "$fail"
