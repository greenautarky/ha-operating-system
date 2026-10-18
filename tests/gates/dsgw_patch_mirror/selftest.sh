#!/usr/bin/env bash
# Self-test for scripts/dsgw210/check-haos-patch-mirror.sh: a copy of the LIVE
# script runs inside throwaway fixture repos, so it resolves REPO there.
#   must-pass: the mirror as the DSGW-210 board has it (docker-engine ->
#              the iHost board's rebased dir, every other HAOS dir a symlink)
#   must-fail: docker-engine pointing at HAOS's 29.7.2 patch (it would meet
#              docker-engine 29.8.2), an upstream patch dir that is not
#              mirrored, a mirror entry HAOS no longer has, a mirror symlink
#              pointing elsewhere, a mirror entry that is a real dir, the
#              iHost rebase dir missing or holding two patches, an empty
#              upstream patch set (zero dirs inspected)
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
live="$repo/scripts/dsgw210/check-haos-patch-mirror.sh"
[ -x "$live" ] || { echo "FAIL: $live not executable"; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bad=0 n=0
mk() { # mk <name> : fixture repo $tmp/<name>
  local r="$tmp/$1" p
  mkdir -p "$r/scripts/dsgw210" "$r/buildroot-dsgw210/patches-haos" "$r/buildroot-ihost/patches-haos/docker-engine"
  for p in docker-engine uboot systemd; do mkdir -p "$r/haos/buildroot-external/patches/$p"; echo x > "$r/haos/buildroot-external/patches/$p/0001-x.patch"; done
  cp "$live" "$r/scripts/dsgw210/"
  echo rebased > "$r/buildroot-ihost/patches-haos/docker-engine/0001-rebased.patch"
  ln -s ../../buildroot-ihost/patches-haos/docker-engine "$r/buildroot-dsgw210/patches-haos/docker-engine"
  ln -s ../../haos/buildroot-external/patches/uboot "$r/buildroot-dsgw210/patches-haos/uboot"
  ln -s ../../haos/buildroot-external/patches/systemd "$r/buildroot-dsgw210/patches-haos/systemd"
}
case_() { # label want-rc substring repo
  local out rc; n=$((n+1))
  out="$("$tmp/$4/scripts/dsgw210/check-haos-patch-mirror.sh" 2>&1)"; rc=$?
  if [ "$rc" = "$2" ] && grep -qF -- "$3" <<<"$out"; then echo "  ok    $1 (rc=$rc)"
  else echo "  FAIL  $1 rc=$rc want $2 '$3' :: $out"; bad=1; fi
}
M=check-dsgw210-haos-patch-mirror
mk good;   case_ "must-pass/dsgw-mirror" 0 "$M: OK" good
mk de;     rm "$tmp/de/buildroot-dsgw210/patches-haos/docker-engine"; ln -s ../../haos/buildroot-external/patches/docker-engine "$tmp/de/buildroot-dsgw210/patches-haos/docker-engine"
case_ "must-fail/docker-engine-points-at-haos-29.7.2" 1 "must resolve to" de
mk nm;     mkdir "$tmp/nm/haos/buildroot-external/patches/rauc"
case_ "must-fail/upstream-dir-not-mirrored" 1 "'rauc' is not mirrored" nm
mk stale;  ln -s ../../haos/buildroot-external/patches/gone "$tmp/stale/buildroot-dsgw210/patches-haos/gone"
case_ "must-fail/stale-mirror-entry" 1 "no longer exists" stale
mk wrong;  rm "$tmp/wrong/buildroot-dsgw210/patches-haos/systemd"; ln -s ../../haos/buildroot-external/patches/uboot "$tmp/wrong/buildroot-dsgw210/patches-haos/systemd"
case_ "must-fail/symlink-points-elsewhere" 1 "does not point at" wrong
mk real;   rm "$tmp/real/buildroot-dsgw210/patches-haos/uboot"; mkdir "$tmp/real/buildroot-dsgw210/patches-haos/uboot"
case_ "must-fail/mirror-entry-is-a-real-dir" 1 "is not mirrored" real
mk noih;   rm -r "$tmp/noih/buildroot-ihost/patches-haos/docker-engine"
case_ "must-fail/ihost-rebase-dir-missing" 1 "must be a real dir" noih
mk two;    echo y > "$tmp/two/buildroot-ihost/patches-haos/docker-engine/0002-extra.patch"
case_ "must-fail/ihost-rebase-dir-has-two-patches" 1 "exactly one patch" two
mk zero;   rm -r "$tmp/zero/haos/buildroot-external/patches"/*; rm -f "$tmp/zero/buildroot-dsgw210/patches-haos"/*
case_ "must-fail/zero-upstream-dirs" 1 "found zero HAOS patch dirs" zero
[ "$n" -ge 9 ] || { echo "FAIL: only $n cases ran"; exit 1; }
echo "$n cases ran"; exit "$bad"
