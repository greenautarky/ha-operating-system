#!/bin/sh
# test_helpers.sh - Minimal test framework for device-side GA tests
# Source this from each test suite script.
# BusyBox /bin/sh compatible (no bash-isms).

_PASS=0
_FAIL=0
_SKIP=0
_SUITE="${GA_TEST_SUITE:-unknown}"

# Colors (if terminal supports it)
if [ -t 1 ]; then
  _GREEN='\033[0;32m'
  _RED='\033[0;31m'
  _YELLOW='\033[0;33m'
  _RESET='\033[0m'
else
  _GREEN='' _RED='' _YELLOW='' _RESET=''
fi

# Run a test: pass description + command string
# Usage: run_test "TEST-01" "description" "command that returns 0 on success"
run_test() {
  _id="$1"
  _desc="$2"
  _cmd="$3"

  if eval "$_cmd" >/dev/null 2>&1; then
    printf "${_GREEN}  PASS${_RESET}  %s: %s\n" "$_id" "$_desc"
    _PASS=$((_PASS+1))
  else
    printf "${_RED}  FAIL${_RESET}  %s: %s\n" "$_id" "$_desc"
    _FAIL=$((_FAIL+1))
  fi
}

# Run a test and capture output for display
# Usage: run_test_show "TEST-01" "description" "command"
run_test_show() {
  _id="$1"
  _desc="$2"
  _cmd="$3"

  _out=$(eval "$_cmd" 2>&1) && _rc=0 || _rc=$?
  if [ "$_rc" -eq 0 ]; then
    printf "${_GREEN}  PASS${_RESET}  %s: %s\n" "$_id" "$_desc"
    _PASS=$((_PASS+1))
  else
    printf "${_RED}  FAIL${_RESET}  %s: %s\n" "$_id" "$_desc"
    _FAIL=$((_FAIL+1))
  fi
  [ -n "$_out" ] && echo "        -> $_out"
}

# Skip a test (manual/destructive)
skip_test() {
  _id="$1"
  _desc="$2"
  _reason="${3:-manual test}"
  printf "${_YELLOW}  SKIP${_RESET}  %s: %s (%s)\n" "$_id" "$_desc" "$_reason"
  _SKIP=$((_SKIP+1))
}

# Print suite header
suite_start() {
  _SUITE="$1"
  echo ""
  echo "=== $_SUITE ==="
}

# Print suite summary + JSON line for machine parsing, return non-zero if any failures
suite_end() {
  echo ""
  _total=$((_PASS + _FAIL + _SKIP))
  echo "--- ${_SUITE}: ${_PASS} passed, ${_FAIL} failed, ${_SKIP} skipped (${_total} total) ---"
  # JSON line for run_all.sh to parse totals
  suite_json
  echo ""
  return $_FAIL
}

# Output results as simple JSON line (for machine parsing)
suite_json() {
  echo "{\"suite\":\"${_SUITE}\",\"pass\":${_PASS},\"fail\":${_FAIL},\"skip\":${_SKIP}}"
}
