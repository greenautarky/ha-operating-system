#!/usr/bin/env bash
# Fixtures for the Go-module SBOM components (Odoo #1272, part 1).
#
#   * Drives the LIVE scripts/go-sbom-merge.py and the LIVE ga_go_sbom_augment in
#     scripts/lib/go-toolchain.sh. Nothing is re-declared here; if either stops
#     being found the suite FAILS (never skips).
#   * green case: fixtures/good - recorded `go version -m` of two real-shaped
#     binaries plus a third not owned by any package, a replace line, a
#     +incompatible version, an upper-case module path, a (devel) main module.
#   * red cases: fixtures/zero-modules (Go binaries, zero modules -> rc 1) and
#     fixtures/no-binaries (nothing to read -> rc 2).
#   * seam: ga_go_sbom_augment over a stub `go` (only `go` is stubbed; the
#     reader ga_go_scan_mods, the merger and the file list are live).
#   * mutants: weakened copies of the live merger must be caught.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/go-toolchain.sh"
PY="$REPO_ROOT/scripts/go-sbom-merge.py"
GAB="$REPO_ROOT/scripts/ga_build.sh"
FX="$HERE/fixtures"
pass=0 fail=0
_pass() { echo "  PASS  $1"; pass=$((pass+1)); }
_fail() { echo "  FAIL  $1"; fail=$((fail+1)); }
echo "=== Go module SBOM components: fixtures ==="
[ -f "$LIB" ] && [ -f "$PY" ] && [ -f "$GAB" ] || { echo "  FAIL  GOSBOM-00: live lib/merger/ga_build.sh not found"; exit 1; }
# shellcheck source=../../../../scripts/lib/go-toolchain.sh
. "$LIB"
declare -F ga_go_sbom_augment >/dev/null && declare -F ga_go_scan_mods >/dev/null \
  || { echo "  FAIL  GOSBOM-00: ga_go_sbom_augment / ga_go_scan_mods not defined by the live lib"; exit 1; }
command -v jq >/dev/null || { echo "  FAIL  GOSBOM-00: jq missing"; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

run_merge() {  # $1 merger  $2 fixture dir -> out in $WORK/out.json, rc in $RC, stderr+stdout in $OUT_TXT
  cp "$2/sbom-in.json" "$WORK/out.json"
  OUT_TXT="$(python3 "$1" "$WORK/out.json" --mods "$2/mods.txt" --file-list "$2/file-list.txt" 2>&1)"; RC=$?
}
J() { jq -r "$1" "$WORK/out.json"; }

# --- must-pass --------------------------------------------------------------
run_merge "$PY" "$FX/good"
[ "$RC" = 0 ] && _pass "GOSBOM-01: good fixture merges (rc 0): $OUT_TXT" || _fail "GOSBOM-01: good fixture rc=$RC: $OUT_TXT"
[ "$(J '.specVersion')" = "1.6" ] && [ "$(J '.bomFormat')" = "CycloneDX" ] && _pass "GOSBOM-02: output stays CycloneDX 1.6" || _fail "GOSBOM-02: specVersion/bomFormat changed"
[ "$(J '[.components[]|select(.purl!=null)]|length')" = 5 ] && _pass "GOSBOM-03: exactly 5 distinct Go module components (x/net and x/sys shared across binaries counted once)" || _fail "GOSBOM-03: component count $(J '[.components[]|select(.purl!=null)]|length'), want 5"
[ "$(J '.components|length')" = 8 ] && _pass "GOSBOM-04: the 3 buildroot package components are untouched (8 total)" || _fail "GOSBOM-04: total components $(J '.components|length'), want 8"
for p in 'pkg:golang/golang.org/x/net@v0.61.0' 'pkg:golang/github.com/burntsushi/toml@v1.4.0' 'pkg:golang/github.com/docker/docker@v28.0.0%2Bincompatible' 'pkg:golang/github.com/netbirdio/pion-old@v1.0.1-nb' 'pkg:golang/golang.org/x/sys@v0.48.0'; do
  [ "$(J "[.components[]|select(.purl==\"$p\")]|length")" = 1 ] && _pass "GOSBOM-05: purl $p" || _fail "GOSBOM-05: purl $p missing or duplicated"
done
[ "$(J '[.components[]|select(.name=="github.com/opencontainers/runc" or .name=="github.com/netbirdio/netbird")]|length')" = 0 ] && _pass "GOSBOM-06: a main module (devel or tagged, here netbird v0.80.0) is not emitted as its own dependency" || _fail "GOSBOM-06: (devel) main module leaked into the SBOM"
[ "$(J '[.dependencies[]|select(.ref=="netbird")][0].dependsOn|length')" = 4 ] && _pass "GOSBOM-07: netbird depends on its 4 modules" || _fail "GOSBOM-07: netbird dependsOn=$(J '[.dependencies[]|select(.ref=="netbird")][0].dependsOn|length')"
[ "$(J '[.dependencies[]|select(.ref=="runc")][0].dependsOn|length')" = 2 ] && _pass "GOSBOM-08: runc depends on its 2 modules" || _fail "GOSBOM-08: runc dependsOn wrong"
[ "$(J '[.dependencies[]|select(.ref=="busybox")][0].dependsOn|length')" = 0 ] && _pass "GOSBOM-09: a non-Go package gains no Go dependency" || _fail "GOSBOM-09: busybox got Go dependencies"
[ "$(J '[.dependencies[]|select(.ref=="ga-os")][0].dependsOn|length')" = 4 ] && _pass "GOSBOM-10: the unowned binary's module attaches to the root (3 packages + x/sys already shared -> 4)" || _fail "GOSBOM-10: root dependsOn=$(J '[.dependencies[]|select(.ref=="ga-os")][0].dependsOn|length')"
grep -q 'unattributed_binaries=1 (usr/bin/stray-tool)' <<<"$OUT_TXT" && _pass "GOSBOM-11: the binary no package owns is named in the summary, not hidden" || _fail "GOSBOM-11: unowned binary not reported: $OUT_TXT"
[ "$(J '[.components[]|select(.name=="github.com/netbirdio/pion-old")][0].properties|map(select(.name=="ga:go-replaces").value)[0]')" = "github.com/pion/old" ] && _pass "GOSBOM-12: a replaced module records what it replaced" || _fail "GOSBOM-12: replace not recorded"
cp "$WORK/out.json" "$WORK/once.json"
python3 "$PY" "$WORK/out.json" --mods "$FX/good/mods.txt" --file-list "$FX/good/file-list.txt" >/dev/null 2>&1
cmp -s "$WORK/out.json" "$WORK/once.json" && _pass "GOSBOM-13: merging twice is idempotent" || _fail "GOSBOM-13: second merge changed the SBOM"

# --- must-fail --------------------------------------------------------------
run_merge "$PY" "$FX/zero-modules"
{ [ "$RC" = 1 ] && grep -q 'ZERO modules extracted' <<<"$OUT_TXT"; } && _pass "GOSBOM-F1: Go binaries but zero modules -> rc 1, loud" || _fail "GOSBOM-F1: rc=$RC out='$OUT_TXT'"
cmp -s "$WORK/out.json" "$FX/zero-modules/sbom-in.json" && _pass "GOSBOM-F2: ...and the SBOM is left untouched" || _fail "GOSBOM-F2: SBOM modified on failure"
run_merge "$PY" "$FX/no-binaries"
{ [ "$RC" = 2 ] && grep -q 'zero Go binaries' <<<"$OUT_TXT"; } && _pass "GOSBOM-F3: zero Go binaries -> rc 2, loud" || _fail "GOSBOM-F3: rc=$RC out='$OUT_TXT'"

# --- seam: the live lib function over a stub go -----------------------------
mkdir -p "$WORK/t/usr/bin" "$WORK/host"
cat > "$WORK/host/go" <<'STUB'
#!/bin/bash
# stub: go version -m DIR -> the fixture in $GOSTUB_SCAN with DIR/ prefixed to header lines
[ "$1" = version ] && [ "$2" = "-m" ] && sed "/^[^[:space:]]/s#^#${3%/}/#" "$GOSTUB_SCAN"
STUB
chmod +x "$WORK/host/go"
seam() {  # $1 fixture dir
  cp "$1/sbom-in.json" "$WORK/seam.json"
  SEAM_TXT="$(GOSTUB_SCAN="$1/mods.txt" ga_go_sbom_augment "$WORK/seam.json" "$WORK/t" "$WORK/host/go" "$1/file-list.txt" "$PY" 2>&1)"; SRC=$?
}
seam "$FX/good"
{ [ "$SRC" = 0 ] && [ "$(jq '[.components[]|select(.purl!=null)]|length' "$WORK/seam.json")" = 5 ]; } && _pass "GOSBOM-S1: ga_go_sbom_augment through the real reader: 5 modules" || _fail "GOSBOM-S1: rc=$SRC $SEAM_TXT"
seam "$FX/zero-modules"; [ "$SRC" = 1 ] && _pass "GOSBOM-S2: seam: zero modules -> rc 1" || _fail "GOSBOM-S2: rc=$SRC"
seam "$FX/no-binaries"; [ "$SRC" = 2 ] && _pass "GOSBOM-S3: seam: no binaries -> rc 2" || _fail "GOSBOM-S3: rc=$SRC"
SEAM_TXT="$(ga_go_sbom_augment "$WORK/seam.json" "$WORK/t" "$WORK/host/nonexistent" "$FX/good/file-list.txt" "$PY" 2>&1)"; SRC=$?
{ [ "$SRC" = 2 ] && grep -q 'GO-SBOM ERROR' <<<"$SEAM_TXT"; } && _pass "GOSBOM-S4: seam: no host go -> rc 2, loud (not a skip)" || _fail "GOSBOM-S4: rc=$SRC"

# --- wiring: generate_sbom calls it BEFORE cve-check and returns 1 on failure
gs="$(sed -n '/^generate_sbom() {/,/^}/p' "$GAB")"
a="$(grep -n 'ga_go_sbom_augment' <<<"$gs" | head -n1 | cut -d: -f1)"; e="$(grep -n 'enrich_sbom_with_cves "\$cyclonedx"' <<<"$gs" | head -n1 | cut -d: -f1)"
{ [ -n "$a" ] && [ -n "$e" ] && [ "$a" -lt "$e" ] && grep -A8 'ga_go_sbom_augment' <<<"$gs" | grep -q 'return 1'; } \
  && _pass "GOSBOM-W1: generate_sbom runs ga_go_sbom_augment before cve-check and returns 1 when it fails (assert_prod_sbom reads that via PIPESTATUS)" \
  || _fail "GOSBOM-W1: generate_sbom wiring missing/misordered"

# --- mutants of the live merger ---------------------------------------------
# zero-modules guard removed: the zero-module fixture must no longer give rc 1... so it would give rc 0
sed 's/    if not modules:/    if False:/' "$PY" > "$WORK/m1.py"; cmp -s "$WORK/m1.py" "$PY" && _fail "GOSBOM-X1: mutant did not apply"
run_merge "$WORK/m1.py" "$FX/zero-modules"; [ "$RC" != 1 ] && _pass "GOSBOM-X1: without the zero-modules guard F1 goes red (rc $RC): the guard is what fires" || _fail "GOSBOM-X1: guard removal not detected"
sed 's/    if not bins:/    if False:/' "$PY" > "$WORK/m2.py"; cmp -s "$WORK/m2.py" "$PY" && _fail "GOSBOM-X2: mutant did not apply"
run_merge "$WORK/m2.py" "$FX/no-binaries"; [ "$RC" != 2 ] && _pass "GOSBOM-X2: without the zero-binaries guard F3 goes red (rc $RC)" || _fail "GOSBOM-X2: guard removal not detected"
sed 's/ref not in d\["dependsOn"\]/False/' "$PY" > "$WORK/m3.py"; cmp -s "$WORK/m3.py" "$PY" && _fail "GOSBOM-X3: mutant did not apply"
run_merge "$WORK/m3.py" "$FX/good"; [ "$(J '[.dependencies[]|select(.ref=="netbird")][0].dependsOn|length')" != 4 ] && _pass "GOSBOM-X3: dropping the dependency edge is caught by GOSBOM-07" || _fail "GOSBOM-X3: not detected"
sed 's/module.lower()/module/' "$PY" > "$WORK/m4.py"; cmp -s "$WORK/m4.py" "$PY" && _fail "GOSBOM-X4: mutant did not apply"
run_merge "$WORK/m4.py" "$FX/good"; [ "$(J '[.components[]|select(.purl=="pkg:golang/github.com/burntsushi/toml@v1.4.0")]|length')" != 1 ] && _pass "GOSBOM-X4: a purl-case regression is caught by GOSBOM-05" || _fail "GOSBOM-X4: not detected"

echo ""; echo "  go-sbom: ${pass} passed, ${fail} failed"
[ "$fail" = 0 ]
