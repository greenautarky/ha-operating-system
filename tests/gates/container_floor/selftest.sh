#!/usr/bin/env bash
# Self-test for scripts/check-container-floor.sh (the LIVE script) and the LIVE
# buildroot-external/container-floor.mk, patches/<pkg>/<pkg>.hash it holds.
# Fixture trees: a fake buildroot package dir (versions as HAOS 18.3 ships
# them, or newer) next to a COPY of the live GA layer files, then mutated.
#   must-pass: the 18.3 versions (floor active), a submodule newer than the
#              floor (floor off, submodule's own hash), the real pinned submodule
#   must-fail: floor line lowered, hash file missing / naming another version,
#              hash value not 64 hex, local.mk without the include, include
#              commented out, floor file missing (rc 2), a package dir missing
#              (rc 2)
# The real-submodule case is mandatory when CONTAINER_FLOOR_REQUIRE_LIVE=1 (CI).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
gate="$repo/scripts/check-container-floor.sh"
[ -x "$gate" ] || { echo "FAIL: $gate not executable"; exit 1; }
# shellcheck source=../../../scripts/lib/tree-paths.sh
. "$repo/scripts/lib/tree-paths.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bad=0 n=0

case_() { # label want-rc expect-substring ext br localmk
  local out rc; n=$((n+1))
  out="$("$gate" "$4" "$5" "$6" 2>&1)"; rc=$?
  if [ "$rc" = "$2" ] && grep -qF -- "$3" <<<"$out"; then echo "  ok    $1 (rc=$rc)"
  else echo "  FAIL  $1 rc=$rc want $2 '$3' :: $out"; bad=1; fi
}
mkbr() { # dir de dc cd [hash-in-submodule]
  mkdir -p "$1/package"/{docker-engine,docker-cli,containerd}
  printf 'DOCKER_ENGINE_VERSION = %s\n' "$2" >"$1/package/docker-engine/docker-engine.mk"
  printf 'DOCKER_CLI_VERSION = %s\n' "$3" >"$1/package/docker-cli/docker-cli.mk"
  printf 'CONTAINERD_VERSION = %s\n' "$4" >"$1/package/containerd/containerd.mk"
  if [ -n "${5:-}" ]; then
    local h=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    printf 'sha256  %s  docker-engine-%s-go2.tar.gz\n' "$h" "$2" >"$1/package/docker-engine/docker-engine.hash"
    printf 'sha256  %s  docker-cli-%s-go2.tar.gz\n' "$h" "$3" >"$1/package/docker-cli/docker-cli.hash"
    printf 'sha256  %s  containerd-%s-go2.tar.gz\n' "$h" "$4" >"$1/package/containerd/containerd.hash"
  fi
}
mkext() { # dir : copy of the live GA files the gate reads
  mkdir -p "$1/patches"
  cp "$repo/$GA_LAYER_DIR/container-floor.mk" "$1/"
  cp -r "$repo/$GA_LAYER_DIR/patches/docker-engine" "$repo/$GA_LAYER_DIR/patches/docker-cli" \
        "$repo/$GA_LAYER_DIR/patches/containerd" "$1/patches/"
}
good_local="$tmp/local-good.mk"
printf 'include $(call qstrip,$(BR2_EXTERNAL_GA_HAOS_PATH))/container-floor.mk\n' >"$good_local"

# --- must-pass
mkbr "$tmp/br183" 29.7.2 29.7.2 2.3.3; mkext "$tmp/ext1"
case_ "must-pass/haos-18.3-versions-floor-active" 0 "container-floor: OK (3 packages inspected)" "$tmp/ext1" "$tmp/br183" "$good_local"
mkbr "$tmp/brnew" 29.9.0 29.9.0 2.4.0 hash
case_ "must-pass/submodule-newer-floor-off" 0 "the GA carry is obsolete" "$tmp/ext1" "$tmp/brnew" "$good_local"
mkbr "$tmp/breq" 29.8.2 29.8.2 2.3.6
case_ "must-pass/submodule-at-floor" 0 "container-floor: OK" "$tmp/ext1" "$tmp/breq" "$good_local"

# --- must-fail
mkext "$tmp/ext2"; sed -i 's/DOCKER_ENGINE:docker-engine:29.8.2/DOCKER_ENGINE:docker-engine:29.7.2/' "$tmp/ext2/container-floor.mk"
case_ "must-fail/floor-lowered" 1 "docker-engine effective version 29.7.2 is below the pinned minimum" "$tmp/ext2" "$tmp/br183" "$good_local"
mkext "$tmp/ext3"; rm "$tmp/ext3/patches/docker-cli/docker-cli.hash"
case_ "must-fail/hash-file-missing" 1 "docker-cli 29.8.2: no sha256 entry" "$tmp/ext3" "$tmp/br183" "$good_local"
mkext "$tmp/ext4"; sed -i 's/containerd-2.3.6-go2/containerd-2.3.3-go2/' "$tmp/ext4/patches/containerd/containerd.hash"
case_ "must-fail/hash-names-other-version" 1 "containerd 2.3.6: no sha256 entry" "$tmp/ext4" "$tmp/br183" "$good_local"
mkext "$tmp/ext5"; sed -i -E 's/^(sha256  )[0-9a-f]{64}(  docker-engine-)/\1deadbeef\2/' "$tmp/ext5/patches/docker-engine/docker-engine.hash"
case_ "must-fail/hash-value-not-sha256" 1 "docker-engine 29.8.2: no sha256 entry" "$tmp/ext5" "$tmp/br183" "$good_local"
: >"$tmp/local-none.mk"
case_ "must-fail/local-mk-without-include" 1 "does not include container-floor.mk" "$tmp/ext1" "$tmp/br183" "$tmp/local-none.mk"
printf '#include $(call qstrip,$(BR2_EXTERNAL_GA_HAOS_PATH))/container-floor.mk\n' >"$tmp/local-commented.mk"
case_ "must-fail/include-commented-out" 1 "does not include container-floor.mk" "$tmp/ext1" "$tmp/br183" "$tmp/local-commented.mk"
mkdir -p "$tmp/ext-none"
case_ "must-fail/floor-file-missing" 2 "container-floor.mk not found" "$tmp/ext-none" "$tmp/br183" "$good_local"
mkbr "$tmp/brhole" 29.7.2 29.7.2 2.3.3; rm "$tmp/brhole/package/containerd/containerd.mk"
case_ "must-fail/package-dir-incomplete" 2 "cannot read CONTAINERD_VERSION" "$tmp/ext1" "$tmp/brhole" "$good_local"

# --- the real thing: live GA files against the pinned submodule
if [ -d "$repo/$GA_HAOS_DIR/buildroot/package/docker-engine" ]; then
  n=$((n+1)); out="$("$gate" 2>&1)"; rc=$?
  if [ "$rc" = 0 ] && grep -qF "container-floor: OK (3 packages inspected)" <<<"$out"; then echo "  ok    must-pass/live-tree-pinned-submodule"
  else echo "  FAIL  live tree rc=$rc :: $out"; bad=1; fi
elif [ "${CONTAINER_FLOOR_REQUIRE_LIVE:-0}" = 1 ]; then
  echo "  FAIL  live tree: haos/buildroot not checked out (CONTAINER_FLOOR_REQUIRE_LIVE=1)"; bad=1
else
  echo "  skip  live tree (haos/buildroot not checked out)"
fi
[ "$n" -ge 10 ] || { echo "FAIL: only $n cases ran"; exit 1; }
echo "$n cases ran"
exit "$bad"
