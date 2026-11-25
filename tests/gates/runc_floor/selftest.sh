#!/usr/bin/env bash
# scripts/check-runc-floor.sh (the LIVE script) over the LIVE runc-floor.mk / runc-floor/ and fixture
# submodules, and against the real pinned submodule (RUNC_FLOOR_REQUIRE_LIVE=1 in CI).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; repo="$(cd "$here/../../.." && pwd)"
gate="$repo/scripts/check-runc-floor.sh"; [ -x "$gate" ] || { echo "FAIL: $gate not executable"; exit 1; }
# shellcheck source=../../../scripts/lib/tree-paths.sh
. "$repo/scripts/lib/tree-paths.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bad=0 n=0
case_() { # label want-rc substring ext br local
  local out rc; n=$((n+1)); out="$("$gate" "$4" "$5" "$6" 2>&1)"; rc=$?
  if [ "$rc" = "$2" ] && grep -qF -- "$3" <<<"$out"; then echo "  ok    $1 (rc=$rc)"; else echo "  FAIL  $1 rc=$rc want $2 '$3' :: $out"; bad=1; fi
}
ext() { mkdir -p "$1"; cp "$repo/$GA_LAYER_DIR/runc-floor.mk" "$1/"; cp -r "$repo/$GA_LAYER_DIR/runc-floor" "$1/"; }
live="$repo/$GA_HAOS_DIR/buildroot/package/runc"
br() { # dir version: the real submodule package dir with another version line
  mkdir -p "$1/package"; cp -r "$live" "$1/package/runc"; sed -i "s/^RUNC_VERSION = .*/RUNC_VERSION = $2/" "$1/package/runc/runc.mk"; }
printf 'include $(call qstrip,$(X))/runc-floor.mk\n' > "$tmp/good.mk"; : > "$tmp/none.mk"; printf '#include runc-floor.mk\n' > "$tmp/com.mk"
if [ ! -d "$live" ]; then
  [ "${RUNC_FLOOR_REQUIRE_LIVE:-0}" = 1 ] && { echo "FAIL: $live not checked out"; exit 1; }
  echo "SKIP: $live not checked out"; exit 0
fi
ext "$tmp/e"; br "$tmp/b" 1.4.3; G="$tmp/good.mk"
case_ "must-pass/1.4.3-floor-active" 0 "effective runc 1.4.4" "$tmp/e" "$tmp/b" "$G"
br "$tmp/b5" 1.4.5; sed -i 's/runc-1.4.3-go2/runc-1.4.5-go2/' "$tmp/b5/package/runc/runc.hash"
case_ "must-pass/submodule-newer-floor-off" 0 "the GA carry is obsolete" "$tmp/e" "$tmp/b5" "$G"
ext "$tmp/e1"; sed -i 's/^GA_RUNC_VERSION_FLOOR = .*/GA_RUNC_VERSION_FLOOR = 1.4.3/' "$tmp/e1/runc-floor.mk"; case_ "must-fail/floor-lowered" 1 "below the pinned minimum" "$tmp/e1" "$tmp/b" "$G"
ext "$tmp/e2"; sed -i 's/runc-1.4.4-go2/runc-1.4.3-go2/' "$tmp/e2/runc-floor/runc.hash"; case_ "must-fail/hash-names-other-version" 1 "no sha256 entry for runc-1.4.4-go2" "$tmp/e2" "$tmp/b" "$G"
ext "$tmp/e3"; sed -i '/LICENSE/d' "$tmp/e3/runc-floor/runc.hash"; case_ "must-fail/licence-hash-missing" 1 "LICENSE" "$tmp/e3" "$tmp/b" "$G"
ext "$tmp/e4"; rm "$tmp/e4/runc-floor/"0005*; case_ "must-fail/a-device-patch-dropped" 1 "does not hold the six pinned patches" "$tmp/e4" "$tmp/b" "$G"
ext "$tmp/e5"; sed -i '/^override RUNC_PKGDIR/d' "$tmp/e5/runc-floor.mk"; case_ "must-fail/pkgdir-redirect-dropped" 1 "HOST_RUNC_PKGDIR" "$tmp/e5" "$tmp/b" "$G"
ext "$tmp/e6"; sed -i '/^override HOST_RUNC_PKGDIR/d' "$tmp/e6/runc-floor.mk"; case_ "must-fail/host-redirect-dropped" 1 "HOST_RUNC_PKGDIR" "$tmp/e6" "$tmp/b" "$G"
br "$tmp/b7" 1.4.3; echo >> "$tmp/b7/package/runc/"0003*.patch; case_ "must-fail/upstream-patch-changed" 1 "re-check the rebase" "$tmp/e" "$tmp/b7" "$G"
br "$tmp/b8" 1.4.3; echo x > "$tmp/b8/package/runc/0007-new.patch"; case_ "must-fail/upstream-patch-added" 1 "re-check the rebase" "$tmp/e" "$tmp/b8" "$G"
case_ "must-fail/no-include" 1 "does not include runc-floor.mk" "$tmp/e" "$tmp/b" "$tmp/none.mk"
case_ "must-fail/include-commented" 1 "does not include runc-floor.mk" "$tmp/e" "$tmp/b" "$tmp/com.mk"
mkdir "$tmp/none"; case_ "must-fail/floor-file-missing" 2 "not found" "$tmp/none" "$tmp/b" "$G"
n=$((n+1)); out="$("$gate" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qF "effective runc 1.4.4, 2 local.mk" <<<"$out"; then echo "  ok    live tree, both boards"; else echo "  FAIL  live rc=$rc $out"; bad=1; fi
[ "$n" -ge 14 ] || { echo "FAIL: only $n cases"; exit 1; }
echo "$n cases ran"; exit "$bad"
