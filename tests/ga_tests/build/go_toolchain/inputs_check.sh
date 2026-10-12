#!/usr/bin/env bash
# Build INPUTS for the Go toolchain: does the tree that CI/the bake checks out
# actually build the rootfs Go packages with Go >= 1.26.9? (Odoo #1231)
#
# GO-2026-6604 and GO-2026-6612 (Go stdlib) are fixed in Go 1.26.9; the
# buildroot submodule pins 1.26.8 and we cannot push there. The carry is
# buildroot-external/go-floor.mk, loaded before package/*/*.mk through
# buildroot-ihost/local.mk, with the tarball hashes in buildroot-external/patches/.
# GOTC-04 (run_build_tests.sh) proves the BUILT binaries; this proves the INPUTS
# without a build, so a regression is red in CI, not in the next bake.
#
#   MIN_GO below is a PINNED constant on purpose: it is not read from go-floor.mk,
#   so lowering the floor there (or deleting the file) is red here.
#   Raise MIN_GO when a newer Go advisory moves the minimum.
#
# Needs the buildroot submodule (make printvars). Without it the check FAILS
# rather than skips: a check that silently stops looking is the failure class
# this file exists to prevent.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${GA_REPO_ROOT:-$(cd "$HERE/../../../.." && pwd)}"
MIN_GO="1.26.9"
EXT="$REPO_ROOT/buildroot-external"
IHOST="$REPO_ROOT/buildroot-ihost"
BR="$REPO_ROOT/buildroot"
DEFCONFIG="ga_ihost_full_defconfig"
pass=0 fail=0
_pass() { echo "  PASS  $1"; pass=$((pass+1)); }
_fail() { echo "  FAIL  $1"; fail=$((fail+1)); }
_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2" ]; }   # $1 >= $2

echo "=== Go toolchain inputs (floor go${MIN_GO}) ==="

# shellcheck source=../../../../scripts/lib/go-toolchain.sh
. "$REPO_ROOT/scripts/lib/go-toolchain.sh" 2>/dev/null || { echo "  FAIL  GOTC-IN-00: scripts/lib/go-toolchain.sh not readable"; exit 1; }

# GOTC-IN-01: the floor exists and is not below the pinned minimum.
floor="$(ga_go_floor_version "$EXT" 2>/dev/null || true)"
if [ -z "$floor" ]; then
  _fail "GOTC-IN-01: no GA_GO_VERSION_FLOOR in buildroot-external/go-floor.mk - the rootfs Go stays on the submodule's version"
elif _ge "$floor" "$MIN_GO"; then
  _pass "GOTC-IN-01: GA_GO_VERSION_FLOOR=$floor >= $MIN_GO"
else
  _fail "GOTC-IN-01: GA_GO_VERSION_FLOOR=$floor is below $MIN_GO (GO-2026-6604 / GO-2026-6612)"
fi

# GOTC-IN-02: the defconfig loads local.mk, and local.mk loads go-floor.mk.
if grep -qE '^BR2_PACKAGE_OVERRIDE_FILE="\$\(BR2_EXTERNAL_IHOST_PATH\)/local\.mk"' "$IHOST/configs/$DEFCONFIG" 2>/dev/null \
   && grep -qE '^include .*go-floor\.mk' "$IHOST/local.mk" 2>/dev/null; then
  _pass "GOTC-IN-02: $DEFCONFIG -> buildroot-ihost/local.mk -> go-floor.mk (included before package/*/*.mk)"
else
  _fail "GOTC-IN-02: go-floor.mk is not reachable from $DEFCONFIG (BR2_PACKAGE_OVERRIDE_FILE / local.mk include) - the floor would never load"
fi

# GOTC-IN-03: hash entries for the floor tarball in the files buildroot reads.
for pkg in go-src go-bin; do
  h="$EXT/patches/$pkg/$pkg.hash"
  if grep -qE "^sha256[[:space:]]+[0-9a-f]{64}[[:space:]]+go${floor:-x}\.src\.tar\.gz$" "$h" 2>/dev/null; then
    _pass "GOTC-IN-03: $pkg.hash carries a sha256 for go${floor}.src.tar.gz"
  else
    _fail "GOTC-IN-03: buildroot-external/patches/$pkg/$pkg.hash has no sha256 for go${floor:-<none>}.src.tar.gz - the download would be refused"
  fi
done

# GOTC-IN-04: the LIVE go-floor.mk, evaluated by make against a go.mk that
# assigns GO_VERSION AFTER it (as buildroot does).
_mk_eval() {  # $1 go.mk version ("" = unreadable) -> prints effective GO_VERSION, or ERR
  local d out; d="$(mktemp -d)"; mkdir -p "$d/package/go"
  [ -n "$1" ] && printf 'GO_VERSION = %s\n' "$1" > "$d/package/go/go.mk"
  cat > "$d/Makefile" <<MK
TOPDIR := $d
include $EXT/go-floor.mk
-include \$(TOPDIR)/package/go/go.mk
all: ; @echo \$(GO_VERSION)
MK
  out="$(make -s -C "$d" all 2>&1)" && printf '%s\n' "$out" || printf 'ERR\n'
  rm -rf "$d"
}
for c in "1.26.8:$floor" "$floor:$floor" "1.26.10:1.26.10" "1.27.0:1.27.0" ":ERR"; do
  in="${c%%:*}"; want="${c#*:}"
  got="$(_mk_eval "$in")"
  [ "$got" = "$want" ] && _pass "GOTC-IN-04: submodule go.mk '${in:-<unreadable>}' -> GO_VERSION ${got}" \
                       || _fail "GOTC-IN-04: submodule go.mk '${in:-<unreadable>}' -> '${got}', want '${want}'"
done

# GOTC-IN-05: what buildroot itself resolves for the real config.
if [ ! -f "$BR/package/go/go.mk" ]; then
  _fail "GOTC-IN-05: buildroot submodule not checked out at $BR - cannot resolve the real Go version (git submodule update --init buildroot)"
else
  O="$(mktemp -d)"
  E="$IHOST:$EXT"
  if make -C "$BR" O="$O" BR2_EXTERNAL="$E" "$DEFCONFIG" >/dev/null 2>&1; then
    vars="$(make -s -C "$BR" O="$O" BR2_EXTERNAL="$E" printvars VARS='HOST_GO_SRC_VERSION HOST_GO_SRC_SOURCE PACKAGES' 2>/dev/null)"
    rv="$(sed -n 's/^HOST_GO_SRC_VERSION=//p' <<<"$vars")"
    rs="$(sed -n 's/^HOST_GO_SRC_SOURCE=//p' <<<"$vars")"
    if [ -z "$rv" ]; then
      _fail "GOTC-IN-05: make printvars returned no HOST_GO_SRC_VERSION for $DEFCONFIG"
    elif ! _ge "$rv" "$MIN_GO"; then
      _fail "GOTC-IN-05: $DEFCONFIG builds the rootfs Go packages with go${rv} (host-go-src), below $MIN_GO"
    elif [ "$rs" != "go${rv}.src.tar.gz" ]; then
      _fail "GOTC-IN-05: host-go-src version $rv but source '$rs'"
    else
      _pass "GOTC-IN-05: $DEFCONFIG builds host-go-src $rv from $rs (>= $MIN_GO)"
    fi
    case " $(sed -n 's/^PACKAGES=//p' <<<"$vars") " in
      *" host-go-src "*) _pass "GOTC-IN-06: host-go-src is the enabled Go provider (the one the floor overrides)" ;;
      *) _fail "GOTC-IN-06: host-go-src is not in PACKAGES - another Go provider is active and the floor does not reach it" ;;
    esac
  else
    _fail "GOTC-IN-05: 'make $DEFCONFIG' failed against $BR"
  fi
  rm -rf "$O"
fi

echo ""
echo "=== Go toolchain inputs: ${pass} passed, ${fail} failed ==="
[ "$fail" -eq 0 ]
