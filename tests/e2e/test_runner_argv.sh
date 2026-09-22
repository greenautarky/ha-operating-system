#!/usr/bin/env bash
# Fixtures for the argv run_e2e_tests.sh hands to Playwright.
#
# Why this file exists: `--suite X --project desktop` produced
#   npx playwright test --project desktop tests/X.spec.ts
# and Playwright's --project is VARIADIC, so it read BOTH words as project
# names and reported `Project(s) "tests/X.spec.ts" not found`. The single-spec
# run that a device measurement needs was therefore impossible, and nothing
# said so — the runner exited having run no test at all. Measured against
# KIB-SON-00000031 on 2026-09-22 while collecting the load-budget proof.
#
# Two fixture sets, and neither is padding:
#   MUST  — argv shapes that have to come out exactly right;
#   MUST-NOT — the shape that caused the failure, so it cannot come back.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$(dirname "$SCRIPT_DIR")/run_e2e_tests.sh"

[[ -x "$RUNNER" ]] || { echo "FAIL: $RUNNER not executable — refusing to report a pass"; exit 1; }

pass=0; fail=0

argv_of() { GA_E2E_PRINT_ARGV=1 "$RUNNER" --ssh root@198.51.100.7 "$@" 2>/dev/null; }

check() {  # name, expected (newline-separated), args...
  local name="$1" expected="$2"; shift 2
  local got; got="$(argv_of "$@")"
  if [[ "$got" == "$expected" ]]; then
    echo "  PASS  $name"; pass=$((pass+1))
  else
    echo "  FAIL  $name"; printf '        expected: %q\n        got:      %q\n' "$expected" "$got"; fail=$((fail+1))
  fi
}

refute() {  # name, forbidden-substring, args...
  local name="$1" forbidden="$2"; shift 2
  local got; got="$(argv_of "$@")"
  if [[ "$got" == *"$forbidden"* ]]; then
    echo "  FAIL  $name — argv still contains $forbidden"; printf '        got: %q\n' "$got"; fail=$((fail+1))
  else
    echo "  PASS  $name"; pass=$((pass+1))
  fi
}

echo "=== run_e2e_tests.sh argv ==="

# MUST: the combination that was impossible.
check "suite + project: one token for the project, then the file" \
      $'--project=desktop\ntests/resident-load-budget.spec.ts' \
      --suite resident-load-budget --project desktop

check "order does not matter" \
      $'--project=desktop\ntests/resident-load-budget.spec.ts' \
      --project desktop --suite resident-load-budget

check "project alone" "--project=mobile-ios" --project mobile-ios
check "suite alone"   "tests/dashboard.spec.ts" --suite dashboard
check "neither: Playwright runs everything" "" 
check "headed keeps its place" \
      $'--project=desktop\n--headed\ntests/dashboard.spec.ts' \
      --project desktop --suite dashboard --headed

# MUST-NOT: the exact shape that swallowed the file.
refute "the project value is never a separate word" \
       $'--project\ndesktop' --suite dashboard --project desktop

echo "--- argv fixtures: $pass passed, $fail failed ---"
[[ $((pass + fail)) -ge 7 ]] || { echo "FAIL: only $((pass+fail)) fixtures ran — refusing to report a pass over nothing"; exit 1; }
[[ $fail -eq 0 ]]
