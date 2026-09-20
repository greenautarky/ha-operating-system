#!/usr/bin/env bash
# gen_expected.sh must work from ANY working directory.
#
# WHAT THIS EXISTS FOR
# ====================
# The generator computed its output path relative to the caller's cwd and then
# cd'd to the repo root, pulling the ground out from under it. So it worked when
# run from the repo root — which is how every human ran it — and failed
# everywhere else:
#
#   _os/tests/ga_tests/os_integrity/gen_expected.sh: line NNN:
#   _os/tests/ga_tests/os_integrity/expected.env: No such file or directory
#
# ga-ops' release-train checks the OS tree out into `_os/` and runs from the
# workspace above it. Its testgate therefore failed on EVERY run since that step
# was added, and the real-boot device suites behind the gate never executed once.
# A gate that is red for a path bug is worse than no gate: it teaches everyone
# to read past the colour, which is what happened across rc41, rc42 and rc43.
#
# Two call shapes, both asserted, because one of them is the one nobody tries.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
GEN="$REPO_ROOT/tests/ga_tests/os_integrity/gen_expected.sh"
OUT="$REPO_ROOT/tests/ga_tests/os_integrity/expected.env"
pass=0 fail=0

_pass() { echo "  PASS  $1"; pass=$((pass+1)); }
_fail() { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "=== gen_expected.sh works from any cwd ==="

[ -x "$GEN" ] || [ -f "$GEN" ] || { echo "  FAIL  GEN-CWD-00: generator not found at $GEN"; exit 1; }
_pass "GEN-CWD-00: generator present"

# Keep the committed file byte-identical whatever this gate does.
BACKUP="$(mktemp)"
cp "$OUT" "$BACKUP" 2>/dev/null || true
restore() { [ -s "$BACKUP" ] && cp "$BACKUP" "$OUT"; rm -f "$BACKUP"; }
trap restore EXIT

# --- GEN-CWD-01: from the repo root (the shape that always worked) ----------
( cd "$REPO_ROOT" && bash "$GEN" >/dev/null 2>&1 )
if [ $? -eq 0 ] && [ -s "$OUT" ]; then
  _pass "GEN-CWD-01: writes expected.env when run from the repo root"
else
  _fail "GEN-CWD-01: failed from the repo root"
fi

# --- GEN-CWD-02: from a FOREIGN cwd, via a relative path -------------------
# This is the release-train's shape: workspace above the checkout, `_os/` prefix.
WORK="$(mktemp -d)"
ln -s "$REPO_ROOT" "$WORK/_os"
_out=""
if _out="$( cd "$WORK" && bash _os/tests/ga_tests/os_integrity/gen_expected.sh 2>&1 )"; then
  _rc=0
else
  _rc=$?
fi
if [ "$_rc" -eq 0 ] && [ -s "$OUT" ]; then
  _pass "GEN-CWD-02: writes expected.env when run as _os/…/gen_expected.sh from above the checkout (the release-train's call)"
else
  _fail "GEN-CWD-02: rc=$_rc from a foreign cwd — the release-train testgate cannot run. Output: $(printf '%s' "$_out" | tail -2)"
fi

# --- GEN-CWD-03: it wrote the REPO's file, not one next to the caller ------
if [ ! -e "$WORK/tests" ] && [ ! -e "$WORK/expected.env" ]; then
  _pass "GEN-CWD-03: nothing was written beside the caller"
else
  _fail "GEN-CWD-03: the generator wrote outside the repo"
fi
rm -rf "$WORK"

# --- GEN-CWD-04: the output really is the pinned release ------------------
# Not padding: a generator that writes an empty or stale file from the wrong
# cwd would satisfy 01-03 and still be useless.
_declared="$(grep -oE '^gaos_release: [^ ]+' "$REPO_ROOT/version.yaml" | awk '{print $2}')"
if grep -q "EXPECTED_GA_RELEASE=\"${_declared}\"" "$OUT"; then
  _pass "GEN-CWD-04: the generated file names the release version.yaml declares (${_declared})"
else
  _fail "GEN-CWD-04: generated file does not name ${_declared} — it ran but produced the wrong content"
fi

echo "--- gen_expected cwd gate: $pass passed, $fail failed"
exit "$fail"
