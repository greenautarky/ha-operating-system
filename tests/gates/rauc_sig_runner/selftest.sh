#!/usr/bin/env bash
# =============================================================================
# selftest.sh -- the REAL RAUC-SIG-01 code of tests/ga_tests/run_build_tests.sh, run against REAL signed bundles
# =============================================================================
# RAUC-SIG-01 (bundle verifies against the keyring the image ships) cannot be judged by the board matrix: it needs a
# bundle signed for the keyring in the image, and this repo holds no signing key for it (Odoo #1632). So it gets its own
# gate. The block is EXTRACTED FROM THE LIVE RUNNER (never re-declared: a copy would stay green while the runner rots)
# and executed in a harness that supplies only _pass/_fail/_skip, OUT and TARGET. If the markers are not found, FAIL.
#   must-pass   a bundle signed by a throwaway CA, the keyring = that CA          -> PASS naming the signer
#   must-flag   a bundle signed by ANOTHER CA                                      -> FAIL (device would reject it)
#               rauc exits 0 but names no signer (output format drift)             -> FAIL, never a pass
#               a bundle older than rootfs.erofs (left over from an earlier build) -> FAIL
#               a rootfs but no bundle                                             -> FAIL (a skip is not allowed on a build output)
#   skip        no rootfs, no bundle (source tree only)                            -> SKIP
#   static      the block names no board (arch / machine / board token): it is board-agnostic by construction
# Needs a real `rauc` (RAUC=<path>, default: on PATH) and openssl; absent -> exit 2, nothing proven.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
RUNNER="${RUNNER:-$ROOT/tests/ga_tests/run_build_tests.sh}"   # RUNNER=<mutated copy> for the red proof
RAUC="${RAUC:-$(command -v rauc || true)}"
[ -n "$RAUC" ] && [ -x "$RAUC" ] || { echo "ERROR: no rauc (set RAUC=<path>) -- nothing proven" >&2; exit 2; }
command -v openssl >/dev/null || { echo "ERROR: openssl missing -- nothing proven" >&2; exit 2; }
W="$(mktemp -d "${TMPDIR:-/tmp}/rsr-XXXXXX")"; trap 'rm -rf "$W"' EXIT
fails=0; ran=0
ok()  { ran=$((ran+1)); echo "  ok    $1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); echo "  FAIL  $1"; }

# ---- the live block --------------------------------------------------------------------------------------------
BLOCK="$(awk '/^  _rauc_bin="\$\(find "\$\{OUT\}\/host" -name rauc/{on=1} /^  # SRC-22:/{on=0} on' "$RUNNER")"
if [ -n "$BLOCK" ] && grep -q 'RAUC-SIG-01' <<<"$BLOCK" && grep -q 'info --keyring=' <<<"$BLOCK"; then
  ok "extracted the RAUC-SIG-01 block from the live runner ($(wc -l <<<"$BLOCK") lines)"
else bad "could not extract the RAUC-SIG-01 block from $RUNNER -- the markers moved: update this gate (never skip)"; echo "$ran cases ran, $fails failed"; exit 1; fi

# ---- throwaway PKI + bundles (real rauc) -----------------------------------------------------------------------
cd "$W" || exit 2
mkpki() { # mkpki <name> -> <name>.pem (CA), <name>leaf.{pem,key}
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.pem" -days 2 -subj "/O=Test/CN=$1-ca" -addext basicConstraints=critical,CA:TRUE >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -keyout "$1leaf.key" -out "$1leaf.csr" -subj "/O=Test/CN=$1-signer" >/dev/null 2>&1
  openssl x509 -req -in "$1leaf.csr" -CA "$1.pem" -CAkey "$1.key" -CAcreateserial -out "$1leaf.pem" -days 2 >/dev/null 2>&1
}
mkpki caA; mkpki caB
mkdir in; head -c 65536 /dev/urandom > in/rootfs.img
printf '[update]\ncompatible=t\nversion=1\n[bundle]\nformat=verity\n[image.rootfs]\nfilename=rootfs.img\n' > in/manifest.raucm
"$RAUC" bundle --cert caAleaf.pem --key caAleaf.key in signedA.raucb >/dev/null 2>&1
"$RAUC" bundle --cert caBleaf.pem --key caBleaf.key in signedB.raucb >/dev/null 2>&1
[ -s signedA.raucb ] && [ -s signedB.raucb ] || { echo "ERROR: rauc could not build the fixture bundles -- nothing proven" >&2; exit 2; }

# build_out <dir> <bundle|-> <rootfs yes|no> : an OUT/TARGET the block can run on; rootfs is dated in the past
build_out() {  # the rauc binary is COPIED: the block finds it with find -type f
  local d="$1"; mkdir -p "$d/host/bin" "$d/images" "$d/target/etc/rauc"
  cp "$RAUC" "$d/host/bin/rauc"; cp caA.pem "$d/target/etc/rauc/keyring.pem"
  if [ "$3" = yes ]; then : > "$d/images/rootfs.erofs"; touch -d '2026-01-01' "$d/images/rootfs.erofs"; fi
  [ "$2" = - ] || { cp "$2" "$d/images/b.raucb"; touch "$d/images/b.raucb"; }
}
run_block() { # run_block <out> -> verdict line(s) on stdout
  ( OUT="$1"; TARGET="$1/target"
    _pass() { echo "PASS $*"; }; _fail() { echo "FAIL $*"; }; _skip() { echo "SKIP $*"; }
    eval "$BLOCK" ) 2>&1
}
expect() { # expect <PASS|FAIL|SKIP> <label> <out> <regex the verdict line must match>: the SPECIFIC reason, not just "something failed"
  local v; v="$(run_block "$3")"
  if [ "$(grep -c '^\(PASS\|FAIL\|SKIP\) RAUC-SIG-01' <<<"$v")" = 1 ] && grep -qE "^$1 RAUC-SIG-01.*$4" <<<"$v"; then ok "$2 -> $1 ($4)"
  else bad "$2: wanted $1 /$4/"; printf '%s\n' "$v" | sed 's/^/        /'; fi
}

echo "must-pass:"
build_out o1 signedA.raucb yes;  expect PASS "bundle signed by the keyring's CA" o1 "verifies against the shipped keyring \(signer"
grep -q "signer: O = Test, CN = caA-signer" <<<"$(run_block o1)" && ok "the verdict names the signer" || bad "the verdict does not name the signer"
echo "must-flag:"
build_out o2 signedB.raucb yes;  expect FAIL "bundle signed by ANOTHER CA" o2 "does NOT verify against the keyring"
build_out o3 signedA.raucb yes;  touch -d '2025-06-01' o3/images/b.raucb; expect FAIL "bundle older than rootfs.erofs (left over)" o3 "is OLDER than rootfs.erofs"
build_out o4 - yes;              expect FAIL "rootfs but no bundle (a skip is not allowed on a build output)" o4 "could not run on a build output"
build_out o5 signedA.raucb yes
printf '#!/bin/sh\nexit 0\n' > fake-rauc; chmod +x fake-rauc; rm -f o5/host/bin/rauc; cp fake-rauc o5/host/bin/rauc
expect FAIL "rauc exits 0 but names no signer (dependency stubbed ONLY to drift its output format)" o5 "named no signer"
echo "skip:"
build_out o6 - no;               expect SKIP "no rootfs and no bundle (source tree only)" o6 "no rauc binary, bundle or keyring"
echo "static:"
if ! grep -qiE 'ihost|dsgw|armv7|aarch64|sonoff|GA_BOARD|_RBT_BOARD|_RBT_ARCH|ga_board_var' <<<"$BLOCK"; then ok "the live block names no board / arch / machine"; else bad "the live block carries a board token: $(grep -oiE 'ihost|dsgw|armv7|aarch64|sonoff|GA_BOARD|_RBT_BOARD|_RBT_ARCH|ga_board_var' <<<"$BLOCK" | sort -u | tr '\n' ' ')"; fi
MUT="$BLOCK"$'\n''  : "$_RBT_ARCH"'
grep -qiE 'ihost|dsgw|armv7|aarch64|sonoff|GA_BOARD|_RBT_BOARD|_RBT_ARCH|ga_board_var' <<<"$MUT" && ok "the token detector goes red on a block that mentions \$_RBT_ARCH" || bad "the token detector is dead"

[ "$ran" -ge 10 ] || { echo "FAIL: only $ran cases ran"; exit 1; }
echo "$ran cases ran, $fails failed"; exit $((fails>0))
