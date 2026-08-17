#!/usr/bin/env bash
# selftest.sh — prove the provisioning gate's GRADING can go red and green.
#
# The gate itself needs a card, a MUX and a power plug, so it cannot run on a
# GitHub runner. Its verdict logic can: `--verify-only <root>` grades a device
# tree with no hardware at all. This runs that path against the same fixtures
# the phase-invariant selftest uses and asserts the EXIT CODE, because that is
# what a caller (a bake job, a cron, a person) will act on.
#
# Measured without a pipe on purpose: `cmd | grep …; echo $?` reports grep's
# status, which is how a gate can look green while failing. That mistake was
# made once while writing this file, which is exactly why the assertion is here.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/provision-e2e.sh"
FIXTURES="$HERE/../ga_tests/provisioning/fixtures"
fails=0
ran=0

[[ -x "$GATE" ]] || { echo "FATAL: $GATE missing or not executable"; exit 1; }
[[ -d "$FIXTURES" ]] || { echo "FATAL: fixtures dir missing: $FIXTURES"; exit 1; }

expect_exit() { # expect_exit <fixture> <wanted-exit>
  local fixture="$1" want="$2" rc out
  out="$("$GATE" --verify-only "$FIXTURES/$fixture" 2>&1)"; rc=$?
  ran=$((ran + 1))
  if [[ "$rc" -eq "$want" ]]; then
    echo "  ok    $fixture → exit $rc"
  else
    echo "  FAIL  $fixture → exit $rc (expected $want)"
    echo "$out" | sed 's/^/        /'
    fails=$((fails + 1))
  fi
}

echo "== the gate must REFUSE these trees =="
expect_exit must-fail-no-identity   1
expect_exit must-fail-parked-pw     1
expect_exit must-fail-baseline-only 1
echo "== and must PASS a finished device =="
expect_exit must-pass-converged     0

echo "== and must refuse to start without a device id =="
if "$GATE" >/dev/null 2>&1; then
  echo "  FAIL  ran without --device (preflight is decoration)"
  fails=$((fails + 1))
else
  rc=$?
  ran=$((ran + 1))
  if [[ $rc -eq 2 ]]; then
    echo "  ok    no --device → exit 2 (refused, not a false pass)"
  else
    echo "  FAIL  no --device → exit $rc (expected 2)"
    fails=$((fails + 1))
  fi
fi

if (( ran == 0 )); then
  echo "FATAL: nothing evaluated"
  exit 1
fi

echo
if (( fails == 0 )); then
  echo "provisioning-gate selftest: $ran/$ran expectations met"
  exit 0
fi
echo "provisioning-gate selftest: $fails of $ran expectations FAILED"
exit 1
