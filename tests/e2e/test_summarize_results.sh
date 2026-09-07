#!/usr/bin/env bash
# Fixtures for the E2E summary, run on every change to it.
#
# The summary this guards was broken for its entire life: it compared a field
# holding expected/unexpected/skipped against "passed"/"failed", so both
# counters were always zero and "ALL PASS" was the only verdict it could reach.
# A red proof pasted into one review would not have caught the next edit, so
# the inputs live here instead — the ones it MUST flag, and the ones it must
# NOT flag. The must-pass set is not padding: a summary that cries wolf is
# ignored, which is a slower way of having no summary at all.
#
# The script under test is invoked as the runner invokes it. Nothing here
# re-implements its logic; a self-test that restates the rule tests a copy.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${DIR}/summarize_results.py"
FIX="${DIR}/fixtures/summary"

[[ -x "${SUT}" ]] || { echo "FAIL: ${SUT} is missing or not executable"; exit 1; }
shopt -s nullglob
FIXTURES=("${FIX}"/*.json)
(( ${#FIXTURES[@]} >= 6 )) || { echo "FAIL: only ${#FIXTURES[@]} fixtures found — refusing to report success over an empty corpus"; exit 1; }

PASS=0; FAIL=0
expect() { # expect <fixture> <exit-code> <substring>
  local f="${FIX}/$1" want_rc="$2" want_txt="$3" out rc
  out="$(python3 "${SUT}" "${f}" 2>&1)"; rc=$?
  if [[ "${rc}" == "${want_rc}" ]] && grep -qF "${want_txt}" <<<"${out}"; then
    PASS=$((PASS+1)); printf '  ok   %-34s rc=%s\n' "$1" "${rc}"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %-34s rc=%s (wanted %s + %s)\n%s\n' "$1" "${rc}" "${want_rc}" "${want_txt}" "${out}"
  fi
}

echo "must NOT be flagged (a summary that flags everything gets ignored)"
expect must-pass-all-green.json        0 "ALL PASS"
expect must-pass-nested-suites.json    0 "2 passed"

echo "must be flagged"
expect must-flag-one-failure.json      1 "1 FAILURES"
expect must-flag-flaky.json            1 "1 FLAKY"
expect must-flag-empty-report.json     2 "ZERO TESTS"
expect must-flag-everything-skipped.json 2 "NOTHING RAN"
expect must-flag-unknown-status.json   2 "UNRECOGNISED REPORT FORMAT"
expect must-flag-malformed.json        2 "NO RESULT"

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
