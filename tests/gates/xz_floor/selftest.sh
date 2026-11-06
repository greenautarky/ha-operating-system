#!/usr/bin/env bash
# Self-test for scripts/check-xz-floor.sh (the LIVE script) against the LIVE
# buildroot-external/xz-floor.mk + xz-floor/ it holds. Fixture trees: a fake
# buildroot package dir next to a COPY of the live GA files, then mutated.
#   must-pass: submodule at 5.6.4 (floor active), submodule newer (floor off,
#              submodule's own hash), submodule at the floor, the real pinned
#              submodule
#   must-fail: floor lowered, hash file missing / naming another version, a
#              licence hash missing, a patch in xz-floor/, PKGDIR redirect
#              dropped (the submodule's patches would apply), local.mk without
#              the include / commented out, floor file missing (rc 2), package
#              dir missing (rc 2)
# The real-submodule case is mandatory when XZ_FLOOR_REQUIRE_LIVE=1 (CI).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
gate="$repo/scripts/check-xz-floor.sh"
[ -x "$gate" ] || { echo "FAIL: $gate not executable"; exit 1; }
# shellcheck source=../../../scripts/lib/tree-paths.sh
. "$repo/scripts/lib/tree-paths.sh"
EXT_REL="$GA_LAYER_DIR"
BR_REL="$GA_HAOS_DIR/buildroot"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bad=0 n=0

case_() { # label want-rc expect-substring ext br localmk
  local out rc; n=$((n+1))
  out="$("$gate" "$4" "$5" "$6" 2>&1)"; rc=$?
  if [ "$rc" = "$2" ] && grep -qF -- "$3" <<<"$out"; then echo "  ok    $1 (rc=$rc)"
  else echo "  FAIL  $1 rc=$rc want $2 '$3' :: $out"; bad=1; fi
}
mkbr() { # dir version [hash-in-submodule]
  mkdir -p "$1/package/xz"
  printf 'XZ_VERSION = %s\n' "$2" >"$1/package/xz/xz.mk"
  if [ -n "${3:-}" ]; then
    printf 'sha256  0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  xz-%s.tar.bz2\n' "$2" >"$1/package/xz/xz.hash"
  fi
}
mkext() { # dir : copy of the live GA files the gate reads
  mkdir -p "$1"
  cp "$repo/$EXT_REL/xz-floor.mk" "$1/"
  cp -r "$repo/$EXT_REL/xz-floor" "$1/"
}
good_local="$tmp/local-good.mk"
printf 'include $(call qstrip,$(BR2_EXTERNAL_X_PATH))/xz-floor.mk\n' >"$good_local"

# --- must-pass
mkbr "$tmp/br564" 5.6.4; mkext "$tmp/ext1"
case_ "must-pass/submodule-5.6.4-floor-active" 0 "xz-floor: OK (effective xz 5.8.4" "$tmp/ext1" "$tmp/br564" "$good_local"
mkbr "$tmp/brnew" 5.9.0 hash
case_ "must-pass/submodule-newer-floor-off" 0 "the GA carry is obsolete" "$tmp/ext1" "$tmp/brnew" "$good_local"
mkbr "$tmp/breq" 5.8.4 hash
case_ "must-pass/submodule-at-floor" 0 "xz-floor: OK" "$tmp/ext1" "$tmp/breq" "$good_local"

# --- must-fail
mkext "$tmp/ext2"; sed -i 's/^GA_XZ_VERSION_FLOOR = .*/GA_XZ_VERSION_FLOOR = 5.6.4/' "$tmp/ext2/xz-floor.mk"
case_ "must-fail/floor-lowered" 1 "xz effective version 5.6.4 is below the pinned minimum" "$tmp/ext2" "$tmp/br564" "$good_local"
mkext "$tmp/ext3"; rm "$tmp/ext3/xz-floor/xz.hash"
case_ "must-fail/hash-file-missing" 1 "no sha256 entry for xz-5.8.4.tar.bz2" "$tmp/ext3" "$tmp/br564" "$good_local"
mkext "$tmp/ext4"; sed -i 's/xz-5.8.4.tar.bz2/xz-5.6.4.tar.bz2/' "$tmp/ext4/xz-floor/xz.hash"
case_ "must-fail/hash-names-other-version" 1 "no sha256 entry for xz-5.8.4.tar.bz2" "$tmp/ext4" "$tmp/br564" "$good_local"
mkext "$tmp/ext5"; sed -i -E 's/^(sha256  )[0-9a-f]{64}(  xz-5)/\1deadbeef\2/' "$tmp/ext5/xz-floor/xz.hash"
case_ "must-fail/hash-value-not-sha256" 1 "no sha256 entry for xz-5.8.4.tar.bz2" "$tmp/ext5" "$tmp/br564" "$good_local"
mkext "$tmp/ext6"; sed -i '/COPYING.LGPLv2.1/d' "$tmp/ext6/xz-floor/xz.hash"
case_ "must-fail/licence-hash-missing" 1 "licence file COPYING.LGPLv2.1" "$tmp/ext6" "$tmp/br564" "$good_local"
mkext "$tmp/ext7"; echo 'x' >"$tmp/ext7/xz-floor/0001-x.patch"
case_ "must-fail/patch-in-floor-dir" 1 "holds patches" "$tmp/ext7" "$tmp/br564" "$good_local"
mkext "$tmp/ext8"; sed -i '/^override XZ_PKGDIR/d' "$tmp/ext8/xz-floor.mk"
case_ "must-fail/pkgdir-redirect-dropped" 1 "in the submodule's xz.hash" "$tmp/ext8" "$tmp/br564" "$good_local"
mkext "$tmp/ext9"; sed -i '/^override HOST_XZ_PKGDIR/d' "$tmp/ext9/xz-floor.mk"
case_ "must-fail/host-pkgdir-redirect-dropped" 1 "HOST_XZ_PKGDIR" "$tmp/ext9" "$tmp/br564" "$good_local"
: >"$tmp/local-none.mk"
case_ "must-fail/local-mk-without-include" 1 "does not include xz-floor.mk" "$tmp/ext1" "$tmp/br564" "$tmp/local-none.mk"
printf '#include $(call qstrip,$(BR2_EXTERNAL_X_PATH))/xz-floor.mk\n' >"$tmp/local-commented.mk"
case_ "must-fail/include-commented-out" 1 "does not include xz-floor.mk" "$tmp/ext1" "$tmp/br564" "$tmp/local-commented.mk"
mkdir -p "$tmp/ext-none"
case_ "must-fail/floor-file-missing" 2 "xz-floor.mk not found" "$tmp/ext-none" "$tmp/br564" "$good_local"
mkbr "$tmp/brhole" 5.6.4; rm "$tmp/brhole/package/xz/xz.mk"
case_ "must-fail/package-dir-incomplete" 2 "xz.mk not found" "$tmp/ext1" "$tmp/brhole" "$good_local"

# --- the real thing: live GA files against the pinned submodule
if [ -f "$repo/$BR_REL/package/xz/xz.mk" ]; then
  n=$((n+1)); out="$("$gate" 2>&1)"; rc=$?
  if [ "$rc" = 0 ] && grep -qF "xz-floor: OK" <<<"$out"; then echo "  ok    must-pass/live-tree-pinned-submodule"
  else echo "  FAIL  live tree rc=$rc :: $out"; bad=1; fi
elif [ "${XZ_FLOOR_REQUIRE_LIVE:-0}" = 1 ]; then
  echo "  FAIL  live tree: haos/buildroot not checked out (XZ_FLOOR_REQUIRE_LIVE=1)"; bad=1
else
  echo "  skip  live tree (haos/buildroot not checked out)"
fi
[ "$n" -ge 13 ] || { echo "FAIL: only $n cases ran"; exit 1; }
echo "$n cases ran"
exit "$bad"
