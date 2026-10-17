#!/usr/bin/env bash
# Self-test for scripts/check-rootfs-size.sh (the LIVE script). Fixture image
# dirs are made with sparse files of a given size (no data written):
#   must-pass: an erofs at 196.9 MiB (the iHost 18.3 measurement of 2026-10),
#              a squashfs exactly at the limit
#   must-fail: one byte over the limit (rc 1), no rootfs image (rc 2), two
#              rootfs images (rc 2), a missing dir (rc 2)
# The limit is read from the gate's OUTPUT for the boundary cases, never
# re-declared here; if that extraction finds nothing, this FAILS.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
gate="$here/../../../scripts/check-rootfs-size.sh"
[ -x "$gate" ] || { echo "FAIL: $gate not executable"; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bad=0 n=0
case_() { # label want-rc expect-substring dir
  local out rc; n=$((n+1))
  out="$("$gate" "$4" 2>&1)"; rc=$?
  if [ "$rc" = "$2" ] && grep -qF -- "$3" <<<"$out"; then echo "  ok    $1 (rc=$rc)"
  else echo "  FAIL  $1 rc=$rc want $2 '$3' :: $out"; bad=1; fi
}
# The limit, from the live gate's own message on a tiny image.
mkdir -p "$tmp/probe"; truncate -s 1 "$tmp/probe/rootfs.erofs"
limit_mib="$("$gate" "$tmp/probe" | sed -nE 's/.*<= ([0-9.]+) MiB.*/\1/p')"
[ -n "$limit_mib" ] || { echo "FAIL: could not read the limit from the live gate's output"; exit 1; }
limit_b="$(awk -v m="$limit_mib" 'BEGIN { printf "%d", m * 1048576 }')"
echo "limit read from the live gate: ${limit_mib} MiB"

mkdir -p "$tmp/ok-ihost"; truncate -s $((1969 * 1048576 / 10)) "$tmp/ok-ihost/rootfs.erofs"
case_ "must-pass/ihost-18.3-measured" 0 "rootfs-size: OK" "$tmp/ok-ihost"
mkdir -p "$tmp/at-limit"; truncate -s "$limit_b" "$tmp/at-limit/rootfs.squashfs"
case_ "must-pass/exactly-at-limit" 0 "rootfs-size: OK" "$tmp/at-limit"
mkdir -p "$tmp/over"; truncate -s $((limit_b + 1)) "$tmp/over/rootfs.erofs"
case_ "must-fail/one-byte-over" 1 "rootfs-size: FAIL" "$tmp/over"
mkdir -p "$tmp/none"; : > "$tmp/none/boot.vfat"
case_ "must-fail/no-rootfs-image" 2 "found 0" "$tmp/none"
mkdir -p "$tmp/two"; truncate -s 1 "$tmp/two/rootfs.erofs"; truncate -s 1 "$tmp/two/rootfs.squashfs"
case_ "must-fail/two-rootfs-images" 2 "found 2" "$tmp/two"
case_ "must-fail/missing-dir" 2 "is not a directory" "$tmp/does-not-exist"
[ "$n" -ge 6 ] || { echo "FAIL: only $n cases ran"; exit 1; }
echo "$n cases ran"
exit "$bad"
