#!/usr/bin/env bash
# Self-test for the BOS release gate (N65, Odoo #2137).
#
# Drives the LIVE gate: scripts/lib/release-gate.sh (sourced, never copied) and
# scripts/create-release.sh itself (end to end, fake image). If the gate code
# cannot be found in either, that is a FAILURE, not a skip (rule 51c).
#
#   must-fail/*.gate.txt  every one must be refused, with the reason named in
#                         its first line (`# EXPECT: <substring>`) so a DIFFERENT
#                         check catching it does not count
#   must-pass/*.gate.txt  complete evidence must release
#   plus: missing evidence file, no --release, override rules, and the archive
#   must not exist after a refusal.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LIB="$ROOT/scripts/lib/release-gate.sh"
CR="$ROOT/scripts/create-release.sh"
PASS=0; FAIL=0
ok()  { echo "  ok    $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# --- the live gate must be findable and wired (never skip) ------------------
[[ -f "$LIB" ]] || { echo "FAIL: $LIB missing - the release gate does not exist" >&2; exit 1; }
[[ -f "$CR" ]] || { echo "FAIL: $CR missing" >&2; exit 1; }
grep -q '^ga_release_gate_check()' "$LIB" || { echo "FAIL: ga_release_gate_check() not defined in $LIB" >&2; exit 1; }
grep -q 'ga_release_gate_check "' "$CR" || { echo "FAIL: create-release.sh never calls ga_release_gate_check - the gate is not wired" >&2; exit 1; }
grep -q 'lib/release-gate.sh' "$CR" || { echo "FAIL: create-release.sh does not source release-gate.sh" >&2; exit 1; }
# shellcheck source=../../../scripts/lib/release-gate.sh
. "$LIB"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
IMGNAME=bos_ihost-18.4.1.6_dev_20261117100010.img.xz
IMG="$T/$IMGNAME"
printf 'ga-release-gate-fixture-image-v1' > "$IMG"
# Pinned constant (rule 7): the fixtures carry this hash; it must be the hash of the image.
PINNED=f4e21e3cde67d089a1612eab4d930e000d87afd8ba6132e992de9c49a59fe297
[[ "$(sha256sum "$IMG" | cut -d' ' -f1)" == "$PINNED" ]] || { echo "FAIL: fixture image hash drifted from the pinned constant" >&2; exit 1; }
REL=BOSv1.6.1-rc2

echo "== gate function: must-fail fixtures (each refused for its OWN reason)"
n=0
for f in "$HERE"/must-fail/*.gate.txt; do
  [[ -f "$f" ]] || continue
  n=$((n + 1))
  want="$(sed -n 's/^# EXPECT: //p' "$f" | head -n 1)"
  out="$(ga_release_gate_check "$f" "$REL" "$IMG")"; rc=$?
  if [[ -z "$want" ]]; then bad "$(basename "$f"): fixture has no '# EXPECT:' line"
  elif [[ $rc -ne 0 && "$out" == *"$want"* ]]; then ok "$(basename "$f") -> refused: $want"
  else bad "$(basename "$f"): rc=$rc, wanted refusal containing '$want', got: $out"; fi
done
[[ $n -ge 10 ]] || bad "only $n must-fail fixtures found (zero-coverage guard)"

out="$(ga_release_gate_check "$T/does-not-exist.gate.txt" "$REL" "$IMG")"; rc=$?
[[ $rc -ne 0 && "$out" == *"no evidence file"* ]] && ok "missing evidence file -> refused" || bad "missing evidence file: rc=$rc $out"
: > "$T/empty.gate.txt"
out="$(ga_release_gate_check "$T/empty.gate.txt" "$REL" "$IMG")"; rc=$?
[[ $rc -ne 0 ]] && ok "empty evidence file -> refused" || bad "empty evidence file passed"

echo "== gate function: must-pass fixtures"
n=0
for f in "$HERE"/must-pass/*.gate.txt; do
  [[ -f "$f" ]] || continue
  n=$((n + 1))
  out="$(ga_release_gate_check "$f" "$REL" "$IMG")"; rc=$?
  [[ $rc -eq 0 ]] && ok "$(basename "$f") -> released" || bad "$(basename "$f") refused: $out"
done
[[ $n -ge 2 ]] || bad "only $n must-pass fixtures found (zero-coverage guard)"

echo "== create-release.sh end to end (live script, fake image)"
BUILD="$T/build"; mkdir -p "$BUILD/images"
cp "$IMG" "$BUILD/images/$IMGNAME"
run_cr() { # run_cr OUTDIR ARGS... ; stdout+stderr in $T/cr.out, rc returned
  local out="$1"; shift
  bash "$CR" --build-dir "$BUILD" --output-dir "$out" "$@" >"$T/cr.out" 2>&1
}
EV="$T/ev"; mkdir -p "$EV"

run_cr "$T/o1" --release "$REL" --evidence-dir "$EV"; rc=$?
if [[ $rc -ne 0 && ! -e "$T/o1" ]] && grep -q 'release gate REFUSES' "$T/cr.out" && grep -q 'no evidence file' "$T/cr.out"; then
  ok "no evidence -> create-release refuses, nothing staged"
else bad "no evidence: rc=$rc, output dir exists=$([[ -e $T/o1 ]] && echo yes || echo no)"; sed 's/^/        /' "$T/cr.out"; fi

run_cr "$T/o2" --evidence-dir "$EV"; rc=$?
[[ $rc -ne 0 && ! -e "$T/o2" ]] && grep -q -- '--release LABEL is required' "$T/cr.out" \
  && ok "no --release -> refused" || bad "no --release: rc=$rc"

cp "$HERE/must-fail/unsigned-ahmad.gate.txt" "$EV/$REL.gate.txt"
run_cr "$T/o3" --release "$REL" --evidence-dir "$EV"; rc=$?
[[ $rc -ne 0 && ! -e "$T/o3" ]] && grep -q "signoff_ahmad is 'PENDING'" "$T/cr.out" \
  && ok "unsigned Ahmad -> create-release refuses and names it" || { bad "unsigned ahmad: rc=$rc"; sed 's/^/        /' "$T/cr.out"; }

# A short / empty override reason is not an override.
run_cr "$T/o4" --release "$REL" --evidence-dir "$EV" --override-gate "x"; rc=$?
[[ $rc -ne 0 && ! -e "$T/o4" ]] && ok "override with a one-letter reason -> refused" || bad "short override accepted: rc=$rc"
run_cr "$T/o4b" --release "$REL" --evidence-dir "$EV" --override-gate ""; rc=$?
[[ $rc -ne 0 && ! -e "$T/o4b" ]] && ok "override with an empty reason -> refused" || bad "empty override accepted: rc=$rc"

run_cr "$T/o5" --release "$REL" --evidence-dir "$EV" --override-gate "Ramin and Ahmad signed by phone, relayed 2026-11-17"; rc=$?
if [[ $rc -eq 0 && -f "$T/o5/${IMGNAME%.img.xz}_release.tar.gz" ]] && grep -q '^gate_override=.*Ramin and Ahmad signed by phone' "$EV/$REL.gate.txt" \
   && grep -q 'RELEASE GATE OVERRIDDEN' "$T/cr.out"; then
  ok "override with a written reason -> released, loud, reason stored in the evidence"
else bad "override with reason: rc=$rc"; sed 's/^/        /' "$T/cr.out"; fi

cp "$HERE/must-fail/sha-mismatch.gate.txt" "$EV/$REL.gate.txt"
run_cr "$T/o6" --release "$REL" --evidence-dir "$EV"; rc=$?
[[ $rc -ne 0 && ! -e "$T/o6" ]] && grep -q 'image_sha256 mismatch' "$T/cr.out" \
  && ok "evidence for another sha256 -> refused" || bad "sha mismatch: rc=$rc"

cp "$HERE/must-fail/run-stopped-at-step-10.gate.txt" "$EV/$REL.gate.txt"
run_cr "$T/o7" --release "$REL" --evidence-dir "$EV"; rc=$?
[[ $rc -ne 0 && ! -e "$T/o7" ]] && ok "run stopped at step 10 (the 2026-11-13 case) -> refused" || bad "step-10 case: rc=$rc"

cp "$HERE/must-pass/complete-rc2.gate.txt" "$EV/$REL.gate.txt"
run_cr "$T/o8" --release "$REL" --evidence-dir "$EV"; rc=$?
if [[ $rc -eq 0 && -f "$T/o8/${IMGNAME%.img.xz}_release.tar.gz" ]] && grep -q 'gate evidence complete' "$T/cr.out"; then
  ok "complete evidence -> create-release releases"
else bad "complete evidence: rc=$rc"; sed 's/^/        /' "$T/cr.out"; fi

# Evidence for rc2 must not release a different label.
run_cr "$T/o9" --release BOSv1.6.1-rc3 --evidence-dir "$EV"; rc=$?
[[ $rc -ne 0 && ! -e "$T/o9" ]] && ok "rc2 evidence does not release rc3" || bad "rc3 released on rc2 evidence: rc=$rc"

echo
echo "release-evidence gate selftest: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
