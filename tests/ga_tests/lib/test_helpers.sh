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

  if ( eval "$_cmd" ) >/dev/null 2>&1; then
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

# wait_for <timeout_s> <command> — poll <command> until it returns 0, up to
# <timeout_s> seconds. Returns 0 as soon as it passes, non-zero on timeout.
#
# WHY THIS EXISTS, and why it is NOT a skip: a fresh flash installs Core and
# converges the add-ons over several minutes, so a suite that runs the instant
# the device is reachable sees a half-built system and reports false failures
# (observed on rc5: OSI-04 red because Core had not been created yet, green a
# few minutes later). A BOUNDED wait removes the timing flake. It must never
# become a mask: on timeout the caller runs the assertion anyway and reports
# the REAL state, so "Core never came up" fails loudly instead of being skipped.
# "Could not become ready in N s" is a failure, not a pass.
wait_for() {
  _to="$1"; shift
  _deadline=$(( $(date +%s) + _to ))
  while :; do
    if ( eval "$@" ) >/dev/null 2>&1; then return 0; fi
    [ "$(date +%s)" -ge "$_deadline" ] && return 1
    sleep 3
  done
}

# run_test_ready <id> <desc> <ready_cmd> <ready_timeout_s> <assert_cmd>
# Waits (bounded) for <ready_cmd>, THEN runs <assert_cmd> as a normal check.
# If readiness times out it still runs the assertion — so a genuinely broken
# subject fails loudly rather than being hidden behind the wait.
run_test_ready() {
  _rid="$1"; _rdesc="$2"; _rready="$3"; _rto="$4"; _rassert="$5"
  if ! wait_for "$_rto" "$_rready"; then
    printf "${_YELLOW}  (readiness for %s timed out after %ss — asserting anyway)${_RESET}\n" "$_rid" "$_rto"
  fi
  run_test_show "$_rid" "$_rdesc" "$_rassert"
}

# Warn: test ran but result is informational (not a failure)
# Usage: warn_test "TEST-01" "description" "command"
warn_test() {
  _id="$1"
  _desc="$2"
  _cmd="$3"

  if ( eval "$_cmd" ) >/dev/null 2>&1; then
    printf "${_GREEN}  PASS${_RESET}  %s: %s\n" "$_id" "$_desc"
    _PASS=$((_PASS+1))
  else
    printf "${_YELLOW}  WARN${_RESET}  %s: %s\n" "$_id" "$_desc"
    _SKIP=$((_SKIP+1))
  fi
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
