#!/usr/bin/env bash
# The GOARCH/GOARM netbird is built with must follow the board's target: the
# iHost (armv7) builds arm/7, the DSGW-210 (aarch64) arm64. Asks Buildroot
# itself (make printvars on each board's defconfig); the expected values are
# PINNED here, never derived from netbird.mk. Needs haos/ and its buildroot
# submodule (it fails, never skips, without them).
set -u
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../../../scripts/lib/tree-paths.sh
. "$REPO/scripts/lib/tree-paths.sh"
BR="$REPO/$GA_HAOS_DIR/buildroot"
[ -f "$BR/package/go/go.mk" ] || { echo "FAIL: $BR not checked out"; exit 1; }
"$REPO/scripts/apply-haos-patches.sh" >/dev/null 2>&1 || { echo "FAIL: patch set does not apply"; exit 1; }
trap '"$REPO/scripts/apply-haos-patches.sh" --revert >/dev/null 2>&1' EXIT
declare -A WANT=( [ihost]="GOARCH=arm GOARM=7" [dsgw210]="GOARCH=arm64" )
bad=0; n=0
for b in $GA_BOARDS; do
  want="${WANT[$b]:-}"; [ -n "$want" ] || { echo "FAIL: no pinned expectation for board $b"; bad=1; continue; }
  d="$REPO/$(ga_board_var BOARD_DIR "$b")"; dc="$(basename "$(ga_board_var DEFCONFIG "$b")")"
  O="$(mktemp -d)"; E="$REPO/$GA_HAOS_DIR/buildroot-external:$d:$REPO/$GA_LAYER_DIR"
  make -C "$BR" O="$O" BR2_EXTERNAL="$E" "$dc" >/dev/null 2>&1 || { echo "FAIL: $b: defconfig does not load"; bad=1; rm -rf "$O"; continue; }
  env="$(make -s -C "$BR" O="$O" BR2_EXTERNAL="$E" printvars VARS=NETBIRD_GO_ENV 2>/dev/null | sed -n 's/^NETBIRD_GO_ENV=//p')"
  rm -rf "$O"
  got="$(tr ' ' '\n' <<<"$env" | grep -E '^GO(ARCH|ARM)=' | sort | tr '\n' ' ' | sed 's/ $//')"
  w="$(tr ' ' '\n' <<<"$want" | sort | tr '\n' ' ' | sed 's/ $//')"
  n=$((n+1))
  if [ "$got" = "$w" ]; then echo "  ok    $b: netbird builds with $got"; else echo "  FAIL  $b: netbird builds with '$got', want '$w'"; bad=1; fi
done
[ "$n" -ge 2 ] || { echo "FAIL: only $n boards inspected"; exit 1; }
exit $bad
