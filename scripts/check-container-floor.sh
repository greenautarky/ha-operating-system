#!/usr/bin/env bash
# check-container-floor.sh — docker-engine, docker-cli and containerd in the
# image are at or above the pinned minimum, and the GA carry that lifts them
# is complete.
#
# Usage: scripts/check-container-floor.sh [EXTERNAL_DIR] [BUILDROOT_DIR] [LOCAL_MK...]
#        defaults: the GA layer (tree-paths.sh), <haos>/buildroot and the
#        local.mk of every board in GA_BOARDS (each must include the floor file)
#
# WHY
#   HAOS 18.3's buildroot ships older docker-engine/docker-cli/containerd than
#   the security releases master already runs. buildroot-external/container-floor.mk
#   lifts them (override before package/*/*.mk, same mechanism as go-floor.mk),
#   with the tarball hashes in patches/<pkg>/<pkg>.hash. Three ways it rots
#   silently: the floor line is edited down, the hash file is missing or names
#   another version (the build then fails late, or a stale hash lingers), or the
#   override stops taking effect and the image keeps the old runtime. The
#   effective version is therefore EVALUATED with make exactly as the build does
#   (floor file first, then the package's own plain assignment), not read back
#   from the floor file.
#
# MIN_* below are PINNED constants (an audit never reads its expected value from
# the artefact it audits). Raise them with a security bump.
#
# Exit: 0 all hold · 1 a check failed · 2 cannot check (never a pass).
set -uo pipefail

MIN_DOCKER_ENGINE=29.8.2
MIN_DOCKER_CLI=29.8.2
MIN_CONTAINERD=2.3.6

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
# shellcheck source=lib/tree-paths.sh
. "$here/lib/tree-paths.sh"
ext="${1:-$repo/$GA_LAYER_DIR}"
br="${2:-$repo/$GA_HAOS_DIR/buildroot}"
mk="$ext/container-floor.mk"
shift 2 2>/dev/null || shift $#
localmks=("$@")
if [ "${#localmks[@]}" -eq 0 ]; then
  for b in $GA_BOARDS; do localmks+=("$repo/$(ga_board_var BOARD_DIR "$b")/local.mk"); done
fi

die() { echo "container-floor: ERROR: $*" >&2; exit 2; }
fail=0
bad() { echo "container-floor: FAIL: $*" >&2; fail=1; }

[ -f "$mk" ] || die "$mk not found"
[ -d "$br/package" ] || die "$br/package not found (is the haos submodule checked out?)"
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
for spec in DOCKER_ENGINE:docker-engine:$MIN_DOCKER_ENGINE DOCKER_CLI:docker-cli:$MIN_DOCKER_CLI CONTAINERD:containerd:$MIN_CONTAINERD; do
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
[ "$n" -eq 3 ] || die "inspected $n packages, expected 3"
[ "$fail" -eq 0 ] && echo "container-floor: OK ($n packages inspected)"
exit "$fail"
