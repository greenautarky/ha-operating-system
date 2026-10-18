#!/usr/bin/env bash
# ga_build.sh decides from the board's external.mk which container images the
# board does not bake (board_skipped_images / board_skips); the container
# inventory and the container image scan follow that decision, and a scan of
# zero images stays a failure for every board that bakes images. This holds the
# LIVE functions (extracted from ga_build.sh, never re-declared here) to
# fixtures, and the REAL board files to pinned expectations.
#   iHost external.mk:   skips nothing
#   DSGW-210 external.mk: skips all seven keys
#   partial / commented / absent file / similar-looking key: nothing is skipped
# If the functions cannot be extracted the check FAILS (it never skips).
set -u
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD="$REPO/scripts/ga_build.sh"
fn="$(awk '/^board_skipped_images\(\)/,/^}/; /^board_skips\(\)/' "$BUILD")"
[ -n "$fn" ] && grep -q 'board_skips()' <<<"$fn" || { echo "FAIL: board_skipped_images/board_skips not found in $BUILD"; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bad=0 n=0
all="supervisor dns audio cli multicast observer core"
check() { # label dir expect-skipped-set("all"|"none"|"list: a b")
  n=$((n+1))
  got="$(BR2EXT_IHOST="$2" bash -c "$fn"'
    for k in '"$all"'; do board_skips "$k" && printf "%s " "$k"; done')"
  got="${got% }"
  if [ "$got" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: skips [$got], want [$3]"; bad=1; fi
}
mk() { mkdir -p "$tmp/$1"; printf '%s\n' "$2" > "$tmp/$1/external.mk"; }
mk allboard 'GA_HASSIO_SKIP_IMAGES = supervisor dns audio cli multicast observer core'
mk partial  'GA_HASSIO_SKIP_IMAGES = supervisor core'
mk commented '# GA_HASSIO_SKIP_IMAGES = supervisor dns audio cli multicast observer core'
mk lookalike 'XGA_HASSIO_SKIP_IMAGES = supervisor core'
mk trailing 'GA_HASSIO_SKIP_IMAGES = supervisor dns audio cli multicast observer core   # no aarch64 images'
mkdir -p "$tmp/nofile"
check "must-skip-all: declaration with all seven keys"        "$tmp/allboard"  "$all"
check "must-skip-all: trailing comment is not a key"          "$tmp/trailing"  "$all"
check "partial declaration skips only what it names"          "$tmp/partial"   "supervisor core"
check "commented-out declaration skips nothing"               "$tmp/commented" ""
check "look-alike variable name skips nothing"                "$tmp/lookalike" ""
check "board without external.mk skips nothing"               "$tmp/nofile"    ""
# the real boards, pinned
. "$REPO/scripts/lib/tree-paths.sh"
check "REAL iHost board bakes every image"                    "$REPO/$(ga_board_var BOARD_DIR ihost)"   ""
check "REAL DSGW-210 board declares all seven skipped"        "$REPO/$(ga_board_var BOARD_DIR dsgw210)" "$all"
[ "$n" -ge 8 ] || { echo "FAIL: only $n cases ran"; exit 1; }
echo "$n cases ran"; exit "$bad"
