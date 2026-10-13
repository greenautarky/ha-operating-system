#!/usr/bin/env bash
# Fixtures for the go-modbump POST_PATCH hook itself (scripts/go-modbump.sh).
#
# WHY: BOSv1.5.1-rc3 failed in containerd's hook: the floor set pulls transitive
# requirements (x/crypto 0.57.0 -> x/sys 0.48.0, x/text 0.42.0 -> x/sync 0.23.0) that
# go-modfloor.sum did not pin, and buildroot's Go has no go.env, so GOSUMDB is empty
# and `go` stops with "verifying go.mod: missing GOSUMDB". Nothing exercised the hook
# before a bake did. This drives the LIVE hook with the REAL `go` against a tiny
# file:// module universe (fixtures/modbump; no network):
#   example.test/a v1.1.0 (used)  -> floor v1.2.0, which REQUIRES example.test/b v1.5.0
#   MH-1 complete pins, GOSUMDB poisoned like buildroot's  -> green, b vendored
#   MH-2 pins lack the transitive module b                 -> FAIL naming example.test/b@v1.5.0
#   MH-3 b's zip differs from the pinned hash              -> FAIL (checksum mismatch)
#   MH-4 floor already met                                 -> kept, nothing to pin
#   mutants of the LIVE hook (GOSUMDB left to the environment, audit not failing)
#   must each be caught by MH-1 / MH-2.
# The real packages are covered by running the hook on each source tree (see PR).
# Needs `go` on PATH: without it this FAILS, it never skips.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
HOOK="$REPO_ROOT/scripts/go-modbump.sh"
FX="$HERE/fixtures/modbump"
pass=0 fail=0
_pass() { echo "  PASS  $1"; pass=$((pass+1)); }
_fail() { echo "  FAIL  $1"; fail=$((fail+1)); }
echo "=== go-modbump hook: transitive pins ==="
GO="$(command -v go || true)"
[ -n "$GO" ] && [ -x "$HOOK" ] || { echo "  FAIL  MH-00: go ($GO) or hook ($HOOK) not found"; exit 1; }
[ -f "$FX/floors.mk" ] || { echo "  FAIL  MH-00: fixtures missing at $FX"; exit 1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
chmod -R u+w "$W" 2>/dev/null

# _run HOOK SUMS [PROXYDIR] -> sets RC, OUT, TREE
_run() {
  local hook="$1" sums="$2" proxy="${3:-$FX/proxy}" t
  t="$(mktemp -d -p "$W")"; cp -a "$FX/pkg" "$t/pkg"; TREE="$t/pkg"
  OUT="$(env -i PATH="$PATH" HOME="$t" GOPATH="$t/gopath" GOMODCACHE="$t/mod" GOCACHE="$t/cache" \
      GOPROXY="file://$proxy" GOFLAGS=-mod=vendor GO111MODULE=on GOSUMDB=' ' GOTOOLCHAIN=local \
      "$hook" "$GO" "$TREE" "$FX/floors.mk" "$sums" 2>&1)"; RC=$?
  chmod -R u+w "$t" 2>/dev/null
}
mk_proxy_tampered() {
  local p="$W/proxy-tampered"; rm -rf "$p"; cp -a "$FX/proxy" "$p"
  cp "$p/example.test/b/@v/v1.5.0.tampered.zip" "$p/example.test/b/@v/v1.5.0.zip"; echo "$p"
}
# the two judgments the mutants are held to
_ok1() { [ "$RC" -eq 0 ] && [ -f "$TREE/vendor/example.test/b/b.go" ] && grep -q 'example.test/a v1.2.0' "$TREE/go.mod"; }
_ok2() { [ "$RC" -ne 0 ] && grep -q 'FATAL: unpinned go.sum entry for example.test/b@v1.5.0' <<<"$OUT"; }

_run "$HOOK" "$FX/sums-complete.sum"
_ok1 && _pass "MH-1: complete pins + empty GOSUMDB -> hook green, a lifted to v1.2.0, b vendored" || _fail "MH-1: rc=$RC :: $OUT"
_run "$HOOK" "$FX/sums-missing-transitive.sum"
_ok2 && _pass "MH-2: transitive module missing from the pins -> hook fails and names example.test/b@v1.5.0" || _fail "MH-2: rc=$RC, message not as expected :: $OUT"
_run "$HOOK" "$FX/sums-complete.sum" "$(mk_proxy_tampered)"
if [ "$RC" -ne 0 ] && grep -qiE 'checksum mismatch|SECURITY ERROR' <<<"$OUT"; then
  _pass "MH-3: a download that differs from the pinned hash is refused (checksum mismatch)"
else _fail "MH-3: tampered module accepted or wrong error: rc=$RC :: $OUT"; fi
# MH-4: floor already met -> kept, no change needed
t="$(mktemp -d -p "$W")"; cp -a "$FX/pkg" "$t/pkg"; sed -i 's#example.test/a v1.1.0#example.test/a v1.2.0#' "$t/pkg/go.mod"
printf 'example.test/a v1.2.0 %s\nexample.test/a v1.2.0/go.mod %s\n' \
  "$(sed -n 's#^example.test/a v1.2.0 ##p' "$FX/sums-complete.sum")" "$(sed -n 's#^example.test/a v1.2.0/go.mod ##p' "$FX/sums-complete.sum")" > "$t/pkg/go.sum"
grep -E '^example.test/b ' "$FX/sums-complete.sum" >> "$t/pkg/go.sum"
OUT="$(env -i PATH="$PATH" HOME="$t" GOPATH="$t/gopath" GOMODCACHE="$t/mod" GOCACHE="$t/cache" GOPROXY="file://$FX/proxy" GOFLAGS=-mod=vendor GOSUMDB=' ' GOTOOLCHAIN=local \
   "$HOOK" "$GO" "$t/pkg" "$FX/floors.mk" "$FX/sums-missing-transitive.sum" 2>&1)"; RC=$?; chmod -R u+w "$t" 2>/dev/null
[ "$RC" -eq 0 ] && grep -q 'example.test/a v1.2.0 >= floor v1.2.0 - kept' <<<"$OUT" && _pass "MH-4: a package already at the floor is kept and needs no extra pins" || _fail "MH-4: rc=$RC :: $OUT"

# --- mutants of the LIVE hook ---------------------------------------------------
_mut() {  # $1 label, $2 sed expr, $3 judgment (_ok1|_ok2) the mutant must FAIL, $4 sums file
  local m="$W/mut-hook.sh"; sed "$2" "$HOOK" > "$m"; chmod +x "$m"
  if cmp -s "$m" "$HOOK"; then _fail "MH-X: mutant '$1' did not apply - the hook changed shape; update the mutant"; return; fi
  _run "$m" "$FX/$4"
  if "$3"; then _fail "MH-X: mutant '$1' still satisfies the fixture - not guarded"; else _pass "MH-X: mutant '$1' caught"; fi
}
_mut "GOSUMDB left to the environment" 's/else export GOSUMDB=off; fi/else :; fi/' _ok2 sums-missing-transitive.sum
_mut "unpinned entries are not fatal" '/FATAL: unpinned/,/bad=1/s/bad=1/bad=0/' _ok2 sums-missing-transitive.sum
_mut "audit loop skipped" 's/^  grep -qxF -- "\$line" "\$KNOWN" \&\& continue/  continue/' _ok2 sums-missing-transitive.sum

echo ""
echo "=== go-modbump hook fixtures: ${pass} passed, ${fail} failed ==="
[ "$fail" -eq 0 ]
