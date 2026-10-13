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

# GOTC-IN-07..08: vendored-module floors (go-modfloor.mk). The MIN_* constants are
# PINNED here on purpose (not read from the file they judge): lowering a floor,
# or deleting the file, is red. BOSv1.5.1-rc2 shipped x/net 0.55-0.59 and x/crypto
# 0.48 (GO-2026-6612 / GHSA-rm3j-f69w-wqmq, Critical). Raise when an advisory moves them.
declare -A MIN_MOD=(
  [golang.org/x/net]="0.60.0"      # GO-2026-6612 Critical (+6603/6610/6611/6617/5942/5026)
  [golang.org/x/crypto]="0.56.0"   # GHSA-rm3j-f69w-wqmq Critical (0.52.0), GO-2026-6354/6355 (0.56.0)
  [golang.org/x/text]="0.39.0"     # GO-2026-5970
  [golang.org/x/mod]="0.40.0"      # GO-2026-6179/6180
)
mfl="$(ga_go_modfloor_list "$EXT" 2>/dev/null || true)"
if [ -z "$mfl" ]; then
  _fail "GOTC-IN-07: no GA_GO_MODFLOOR lines readable from buildroot-external/go-modfloor.mk - the vendored x/net, x/crypto stay as upstream resolved them"
else
  for m in "${!MIN_MOD[@]}"; do
    have="$(awk -v m="$m" '$1==m{print $2}' <<<"$mfl" | head -n 1)"; have="${have#v}"
    if [ -z "$have" ]; then _fail "GOTC-IN-07: go-modfloor.mk has no floor for $m (pinned minimum v${MIN_MOD[$m]})"
    elif _ge "$have" "${MIN_MOD[$m]}"; then _pass "GOTC-IN-07: floor $m v$have >= v${MIN_MOD[$m]}"
    else _fail "GOTC-IN-07: floor $m v$have is below v${MIN_MOD[$m]}"; fi
    # the floor release must be hash-pinned (module hash AND go.mod hash)
    if [ -n "$have" ] && grep -qE "^$m v$have h1:[A-Za-z0-9+/=]{44}$" "$EXT/go-modfloor.sum" 2>/dev/null \
       && grep -qE "^$m v$have/go.mod h1:[A-Za-z0-9+/=]{44}$" "$EXT/go-modfloor.sum" 2>/dev/null; then
      _pass "GOTC-IN-08: go-modfloor.sum pins $m v$have (module + go.mod hash)"
    else
      _fail "GOTC-IN-08: go-modfloor.sum does not pin $m v${have:-<none>} (module + go.mod h1 lines)"
    fi
  done
fi
[ -x "$REPO_ROOT/scripts/go-modbump.sh" ] && _pass "GOTC-IN-08: scripts/go-modbump.sh is executable" || _fail "GOTC-IN-08: scripts/go-modbump.sh missing or not executable"
grep -qE '^include .*go-modfloor\.mk' "$EXT/external.mk" 2>/dev/null \
  && _pass "GOTC-IN-08: external.mk includes go-modfloor.mk (every board that uses the external tree)" \
  || _fail "GOTC-IN-08: external.mk does not include go-modfloor.mk - the POST_PATCH hooks would never load"

# GOTC-IN-10: the module-floor exemption list (go-modfloor.exempt). Everything the
# exemption may say is a PINNED constant HERE, not read from the file it judges:
# editing the file alone cannot extend the expiry, add a binary, or move the
# version. Changing an exemption means changing this block in review.
X_PATH="usr/bin/runc"; X_MOD="golang.org/x/net"; X_VER="v0.43.0"; X_LAST_EXPIRY="2026-11-30"
X_ADV="GO-2026-4440,GO-2026-4441,GO-2026-4918,GO-2026-5025,GO-2026-5026,GO-2026-5027,GO-2026-5028,GO-2026-5029,GO-2026-5030,GO-2026-5942,GO-2026-6603,GO-2026-6610,GO-2026-6611,GO-2026-6612,GO-2026-6617"
xl="$(ga_go_modfloor_exempt_list "$EXT" 2>/dev/null || true)"
nx="$(grep -c . <<<"$xl" || true)"
if [ "$nx" != "1" ]; then
  _fail "GOTC-IN-10: go-modfloor.exempt holds $nx entries, want exactly 1 ($X_PATH $X_MOD) - a new exemption needs this pinned block changed in review"
else
  IFS='|' read -r xp xm xv xa xe xr <<<"$xl"
  if [ "$xp|$xm|$xv|$xa" = "$X_PATH|$X_MOD|$X_VER|$X_ADV" ]; then _pass "GOTC-IN-10: exemption is exactly $X_PATH / $X_MOD $X_VER / 15 pinned advisory ids"
  else _fail "GOTC-IN-10: exemption '$xp|$xm|$xv|$xa' differs from the pinned '$X_PATH|$X_MOD|$X_VER|$X_ADV'"; fi
  if [[ "$xe" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && ! [[ "$xe" > "$X_LAST_EXPIRY" ]]; then _pass "GOTC-IN-10: expiry $xe is not later than the pinned $X_LAST_EXPIRY"
  else _fail "GOTC-IN-10: expiry '$xe' is missing/malformed or later than $X_LAST_EXPIRY (extension needs Thomas' decision and this constant changed)"; fi
  if [ "${#xr}" -ge 40 ]; then _pass "GOTC-IN-10: the exemption carries a reason"; else _fail "GOTC-IN-10: exemption reason missing or too short"; fi
  today="$(date +%F)"
  if [[ "$xe" > "$today" || "$xe" == "$today" ]]; then _pass "GOTC-IN-10: exemption not expired (expires $xe, today $today)"
  else _fail "GOTC-IN-10: exemption for $xp EXPIRED $xe (today $today) - bump the module (RUNC_GA_MODBUMP hook) or re-decide"; fi
fi

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
    # GOTC-IN-09: every ENABLED package that vendors Go modules at download time
    # (DOWNLOAD_POST_PROCESS = go) has the go-modbump POST_PATCH hook. A Go package
    # added later without it would ship whatever x/net its upstream resolved to.
    pk="$(sed -n 's/^PACKAGES=//p' <<<"$vars")"
    q=""; for p in $pk; do [[ "$p" == host-* ]] && continue; u="$(printf '%s' "$p" | tr 'a-z-' 'A-Z_')"; q="$q ${u}_DOWNLOAD_POST_PROCESS ${u}_POST_PATCH_HOOKS"; done
    pv="$(make -s -C "$BR" O="$O" BR2_EXTERNAL="$E" printvars VARS="$q" 2>/dev/null)"
    ngo=0; nexempt=0; missing=""
    for p in $pk; do
      [[ "$p" == host-* ]] && continue
      u="$(printf '%s' "$p" | tr 'a-z-' 'A-Z_')"
      dp="$(sed -n "s/^${u}_DOWNLOAD_POST_PROCESS=//p" <<<"$pv")"
      [ "$dp" = "go" ] || continue
      ngo=$((ngo+1))
      # PINNED exemption: runc is the only Go package without a hook; GOTC-IN-10 holds its
      # go-modfloor.exempt entry (version, advisories, expiry) to pinned constants.
      hk="$(sed -n "s/^${u}_POST_PATCH_HOOKS=//p" <<<"$pv")"
      if [ "$p" = "runc" ]; then
        nexempt=$((nexempt+1))
        case " $hk " in *" RUNC_GA_MODBUMP "*) missing="$missing runc(has BOTH a hook and an exemption - remove the exemption)";; esac
        continue
      fi
      case " $hk " in *" ${u}_GA_MODBUMP "*) ;; *) missing="$missing $p";; esac
    done
    if [ "$ngo" -eq 0 ]; then _fail "GOTC-IN-09: found no Go package in PACKAGES - the discriminator (DOWNLOAD_POST_PROCESS=go) is broken, not the tree"
    elif [ -n "$missing" ]; then _fail "GOTC-IN-09: Go packages without a go-modbump hook (add <PKG>_GA_MODBUMP in go-modfloor.mk):$missing"
    else _pass "GOTC-IN-09: all $ngo enabled Go packages are covered: $((ngo-nexempt)) carry the go-modbump hook, $nexempt covered by the pinned runc exemption (GOTC-IN-10)"; fi
    # the hook expands to the script, the floors and the sums (not an empty string)
    hv="$(make -s -C "$BR" O="$O" BR2_EXTERNAL="$E" printvars VARS='NETBIRD_GA_MODBUMP DOCKER_CLI_GA_MODBUMP' 2>/dev/null)"
    if grep -q 'scripts/go-modbump.sh' <<<"$hv" && grep -q 'go-modfloor.mk' <<<"$hv" && grep -q 'go-modfloor.sum' <<<"$hv" && sed -n 's/^DOCKER_CLI_GA_MODBUMP=//p' <<<"$hv" | grep -q 'vendor\.mod'; then
      _pass "GOTC-IN-09: the hook expands to go-modbump.sh + go-modfloor.mk + go-modfloor.sum (docker-cli with vendor.mod)"
    else
      _fail "GOTC-IN-09: NETBIRD_GA_MODBUMP / DOCKER_CLI_GA_MODBUMP do not expand to the script, floors and sums"
    fi
  else
    _fail "GOTC-IN-05: 'make $DEFCONFIG' failed against $BR"
  fi
  rm -rf "$O"
fi

echo ""
echo "=== Go toolchain inputs: ${pass} passed, ${fail} failed ==="
[ "$fail" -eq 0 ]
