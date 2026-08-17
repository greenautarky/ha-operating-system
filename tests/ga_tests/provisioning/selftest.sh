#!/usr/bin/env bash
# selftest.sh — prove the converge phase invariants can go BOTH red and green.
#
# Runs `check_phase_invariants.sh` — the LIVE definition, not a copy — against
# fixture device trees whose correct verdict is known in advance. Same reasoning
# as tests/gates/run_gate_selftests.sh: a paste of failing output is evidence
# once, about one version. This is evidence on every PR.
#
# must-pass is not padding. A check that flags every device gets ignored, which
# is a slower way of having no check at all — so the finished-device tree is
# asserted green just as hard as the broken ones are asserted red.
#
# Fixtures (tests/ga_tests/provisioning/fixtures/):
#   must-fail-no-identity    the measured K31 state — marker written, identity
#                            landed nine seconds later, so device_id/url_prefix
#                            are missing while the device claims convergence
#   must-fail-parked-pw      converged + identified, but a generated admin
#                            password is still parked = nobody else has it
#   must-fail-baseline-only  baseline done, per-device phase outstanding
#   must-pass-converged      what a finished device looks like
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/check_phase_invariants.sh"
FIXTURES="$HERE/fixtures"
fails=0
ran=0

[[ -x "$CHECK" ]] || { echo "FATAL: $CHECK missing or not executable"; exit 1; }
[[ -d "$FIXTURES" ]] || { echo "FATAL: fixtures dir $FIXTURES missing"; exit 1; }

# verdict <fixture> <check-id> → pass|fail|skip|absent
verdict() {
  local out
  out="$(sh "$CHECK" "$FIXTURES/$1" 2>/dev/null | awk -v id="$2" '$1==id {print $2; exit}')"
  echo "${out:-absent}"
}

expect() {
  local fixture="$1" id="$2" want="$3" got
  got="$(verdict "$fixture" "$id")"
  ran=$((ran + 1))
  if [[ "$got" == "$want" ]]; then
    echo "  ok    $fixture/$id → $got"
  else
    echo "  FAIL  $fixture/$id → $got (expected $want)"
    fails=$((fails + 1))
  fi
}

echo "== must-fail-no-identity (the measured K31 state) =="
expect must-fail-no-identity PROV-08 fail   # the invariant that was violated
expect must-fail-no-identity PROV-09 fail   # no PIN either
expect must-fail-no-identity PROV-07 pass   # baseline marker is there

echo "== must-fail-parked-pw =="
expect must-fail-parked-pw PROV-10 fail
expect must-fail-parked-pw PROV-08 pass     # identity is fine here …
expect must-fail-parked-pw PROV-09 pass     # … and so is the PIN

echo "== must-fail-baseline-only =="
expect must-fail-baseline-only PROV-07 pass
expect must-fail-baseline-only PROV-08 fail # outstanding, not "ok"
expect must-fail-baseline-only PROV-09 skip # PROV-08 already says it

echo "== must-pass-converged (must NOT be flagged) =="
expect must-pass-converged PROV-07 pass
expect must-pass-converged PROV-08 pass
expect must-pass-converged PROV-09 pass
expect must-pass-converged PROV-10 pass

# Fail closed on zero: a harness that inspected nothing is a failure, not a pass.
if (( ran == 0 )); then
  echo "FATAL: no expectations evaluated — fixtures or extraction broken"
  exit 1
fi

echo
if (( fails == 0 )); then
  echo "phase-invariant selftest: $ran/$ran expectations met (red AND green proven)"
  exit 0
fi
echo "phase-invariant selftest: $fails of $ran expectations FAILED"
exit 1
