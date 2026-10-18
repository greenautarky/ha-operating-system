#!/usr/bin/env bash
# Self-test for scripts/ihost/check-haos-patch-mirror.sh (a copy of the LIVE
# script runs inside a throwaway repo, so it resolves REPO there). The real
# upstream docker-engine patch is taken from haos/ (fails if haos/ is absent).
#   must-pass: the mirror as the iHost board has it (docker-engine and uboot
#              real dirs with one patch each, the rest symlinks)
#   must-fail: docker-engine back to a symlink (the 29.7.2 patch would meet
#              docker-engine 29.8.2), upstream docker patch changed, two
#              patches in the replacement dir, replacement patch is a symlink,
#              an upstream patch dir that is not mirrored, uboot replaced by a
#              symlink
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
live="$repo/scripts/ihost/check-haos-patch-mirror.sh"
up="$repo/haos/buildroot-external/patches"
[ -x "$live" ] || { echo "FAIL: $live not executable"; exit 1; }
[ -d "$up/docker-engine" ] || { echo "FAIL: haos/ not checked out ($up/docker-engine missing)"; exit 1; }
DP=0001-bridge-protect-bridge-subnet-from-direct-external-ac.patch
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bad=0 n=0
mk() { # mk <name> : fixture repo $tmp/<name> mirroring the iHost layout
  local r="$tmp/$1" p
  mkdir -p "$r/scripts/ihost" "$r/haos/buildroot-external/patches/docker-engine" "$r/haos/buildroot-external/patches/uboot" \
           "$r/haos/buildroot-external/patches/systemd" "$r/buildroot-ihost/patches-haos/docker-engine" "$r/buildroot-ihost/patches-haos/uboot"
  cp "$live" "$r/scripts/ihost/"
  cp "$up/docker-engine/$DP" "$r/haos/buildroot-external/patches/docker-engine/"
  echo x > "$r/haos/buildroot-external/patches/uboot/0001-CMD-read-string-from-fileinto-env.patch"
  echo x > "$r/haos/buildroot-external/patches/systemd/0001-x.patch"
  echo rebased > "$r/buildroot-ihost/patches-haos/docker-engine/$DP"
  echo x > "$r/buildroot-ihost/patches-haos/uboot/0001-CMD-read-string-from-fileinto-env.patch"
  ln -s ../../haos/buildroot-external/patches/systemd "$r/buildroot-ihost/patches-haos/systemd"
}
case_() { # label want-rc substring repo
  local out rc; n=$((n+1))
  out="$("$tmp/$4/scripts/ihost/check-haos-patch-mirror.sh" 2>&1)"; rc=$?
  if [ "$rc" = "$2" ] && grep -qF -- "$3" <<<"$out"; then echo "  ok    $1 (rc=$rc)"
  else echo "  FAIL  $1 rc=$rc want $2 '$3' :: $out"; bad=1; fi
}
mk good;        case_ "must-pass/ihost-mirror" 0 "check-haos-patch-mirror: OK" good
mk sym;         rm -r "$tmp/sym/buildroot-ihost/patches-haos/docker-engine"; ln -s ../../haos/buildroot-external/patches/docker-engine "$tmp/sym/buildroot-ihost/patches-haos/docker-engine"
case_ "must-fail/docker-engine-symlink" 1 "docker-engine/ must be a real dir" sym
mk upchg;       echo changed >> "$tmp/upchg/haos/buildroot-external/patches/docker-engine/$DP"
case_ "must-fail/upstream-docker-patch-changed" 1 "changed upstream" upchg
mk two;         echo y > "$tmp/two/buildroot-ihost/patches-haos/docker-engine/0002-extra.patch"
case_ "must-fail/two-patches-in-replacement" 1 "exactly the rebased" two
mk lnk;         rm "$tmp/lnk/buildroot-ihost/patches-haos/docker-engine/$DP"; ln -s "$tmp/lnk/haos/buildroot-external/patches/docker-engine/$DP" "$tmp/lnk/buildroot-ihost/patches-haos/docker-engine/$DP"
case_ "must-fail/replacement-patch-is-symlink" 1 "regular file" lnk
mk newdir;      mkdir "$tmp/newdir/haos/buildroot-external/patches/rauc"
case_ "must-fail/upstream-dir-not-mirrored" 1 "'rauc' is not mirrored" newdir
mk ub;          rm -r "$tmp/ub/buildroot-ihost/patches-haos/uboot"; ln -s ../../haos/buildroot-external/patches/uboot "$tmp/ub/buildroot-ihost/patches-haos/uboot"
case_ "must-fail/uboot-symlink" 1 "uboot/ must be a real dir" ub
[ "$n" -ge 7 ] || { echo "FAIL: only $n cases ran"; exit 1; }
echo "$n cases ran"; exit "$bad"
