#!/bin/sh
# test_helpers.sh - Minimal test framework for device-side GA tests
# Source this from each test suite script.
# BusyBox /bin/sh compatible (no bash-isms).

# Where Supervisor keeps add-on data on THIS image. Same rule as the OS-side resolver
# (/usr/libexec/ga-data-root.sh), probed here and not sourced from the image under test:
# the RUNNING Supervisor decides (io.hass.version label of hassio_supervisor: >= 2026.10
# -> apps/data, below -> addons/data), because a rolled-back device keeps a stale apps/.
# Supervisor not running: the tree holding a *_ga_manager dir, the newer one if both.
# Nothing decidable = the addons/ path, so a check reports an absent directory
# instead of an empty variable.
_ga_t_sv="$(docker inspect -f '{{index .Config.Labels "io.hass.version"}}' hassio_supervisor 2>/dev/null)" || _ga_t_sv=""
_ga_t_ym="$(printf '%s\n' "$_ga_t_sv" | sed -n 's/^\([0-9]\{4\}\)\.\([0-9]\{1,2\}\)\..*/\1 \2/p')"
if [ -n "$_ga_t_ym" ]; then
    _ga_t_y="${_ga_t_ym% *}"; _ga_t_m="${_ga_t_ym#* }"
    if [ "$_ga_t_y" -gt 2026 ] || { [ "$_ga_t_y" -eq 2026 ] && [ "$_ga_t_m" -ge 10 ]; }; then GA_T_DATA_ROOT=/mnt/data/supervisor/apps/data
    else GA_T_DATA_ROOT=/mnt/data/supervisor/addons/data; fi
else
    _ga_t_a=""; _ga_t_o=""
    for _ga_t_d in /mnt/data/supervisor/apps/data/*_ga_manager; do [ -d "$_ga_t_d" ] && _ga_t_a="$_ga_t_d"; done
    for _ga_t_d in /mnt/data/supervisor/addons/data/*_ga_manager; do [ -d "$_ga_t_d" ] && _ga_t_o="$_ga_t_d"; done
    if [ -n "$_ga_t_a" ] && { [ -z "$_ga_t_o" ] || [ "$_ga_t_a" -nt "$_ga_t_o" ]; }; then GA_T_DATA_ROOT=/mnt/data/supervisor/apps/data
    else GA_T_DATA_ROOT=/mnt/data/supervisor/addons/data; fi
fi
export GA_T_DATA_ROOT
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

# Add-on container names. Supervisor 2025.11.x (BOSv1.5.x) names them
# addon_<hash>_<slug>; Supervisor 2026.10+ (BOSv1.6) names them app_<hash>_<slug>
# (measured on a BOSv1.6 device, Supervisor 2026.10.5.3, 2026-11-10). A rolled-back
# device can hold both, so the NEW name wins. Anything that anchors on one prefix
# is blind on the other release (tests/gates/container_names guards that).
#   ga_ctr_names          all add-on container names, one per line (app_ first)
#   ga_ctr_of <slug>      running container whose name ends _<slug>; empty (rc 1) if absent
#   ga_ctr_exact <h_slug> running container <prefix>_<h_slug> e.g. 99f1cad4_ga_manager
# When there is NO app_/addon_ container at all the naming scheme itself is
# unknown (Supervisor down, or a third scheme): that is said LOUDLY on stderr.
# An absent slug under a known scheme is silent - callers use it as a probe.
ga_ctr_names() {
  _gct_all=$(docker ps --format '{{.Names}}' 2>/dev/null)
  _gct_n=$(printf '%s\n' "$_gct_all" | grep -E '^app_'; printf '%s\n' "$_gct_all" | grep -E '^addon_')
  if [ -z "$_gct_n" ]; then
    echo "ga-test: ERROR: no app_* and no addon_* container is running - add-on container naming unresolved" >&2
    return 1
  fi
  printf '%s\n' "$_gct_n"
}
ga_ctr_of() {
  _gco_n=$(ga_ctr_names) || return 1
  _gco_r=$(printf '%s\n' "$_gco_n" | grep -E "^(app|addon)_.*_$1\$" | head -1)
  [ -n "$_gco_r" ] && { printf '%s\n' "$_gco_r"; return 0; }
  return 1
}
ga_ctr_exact() {
  for _gce_p in app addon; do
    if docker inspect -f '{{.State.Running}}' "${_gce_p}_$1" >/dev/null 2>&1; then
      printf '%s_%s\n' "$_gce_p" "$1"; return 0
    fi
  done
  echo "ga-test: ERROR: neither app_$1 nor addon_$1 exists" >&2
  return 1
}

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

# show_verdict <id> <desc> <rc> <reason> — report a verdict a function already
# reached: PASS when <rc> is 0, FAIL otherwise (a non-numeric <rc> is a FAIL),
# then the reason on its own line, exactly as given.
#
# No eval. A reason pasted into a command string (echo '$MSG') and then
# eval'd breaks on the first apostrophe in the reason — "unterminated quoted
# string" — and a correct PASS is reported as a FAIL. That happened on a real
# device run with the reason "the boot left the image's password". Pass
# reasons here instead.
show_verdict() {
  _id="$1"
  _desc="$2"
  _vrc="$3"
  _why="$4"
  if [ "$_vrc" -eq 0 ] 2>/dev/null; then
    printf "${_GREEN}  PASS${_RESET}  %s: %s\n" "$_id" "$_desc"
    _PASS=$((_PASS+1))
  else
    printf "${_RED}  FAIL${_RESET}  %s: %s\n" "$_id" "$_desc"
    _FAIL=$((_FAIL+1))
  fi
  [ -n "$_why" ] && printf '        -> %s\n' "$_why"
  return 0
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

# --- Home Assistant port (ADR-0038) -----------------------------------------
# Core 2026.8+ serves on :80, older Core on :8123. Never hard-code either; see
# ha_port.sh for the resolution order. The file sits next to this one; the
# lookup does not rely on the caller's SCRIPT_DIR because some callers define
# none.
_th_lib="${GA_TESTS_LIB:-${SCRIPT_DIR:-.}/../lib}"
[ -f "$_th_lib/ha_port.sh" ] || _th_lib="$(dirname "$0")/../lib"
# shellcheck source=ha_port.sh
[ -f "$_th_lib/ha_port.sh" ] && . "$_th_lib/ha_port.sh"

# require_ha_port <id> — set HA_PORT and HA_BASE (http://127.0.0.1:<port>) for
# this suite. When the port cannot be resolved it records ONE failing test with
# the reason and points HA_BASE at an unusable URL, so every HTTP check after it
# fails too instead of quietly probing a port the helper guessed.
require_ha_port() {
  if command -v _ga_ha_port_resolve >/dev/null 2>&1 && _ga_ha_port_resolve 2>"${TMPDIR:-/tmp}/ga-ha-port.err"; then
    HA_PORT="$GA_HA_PORT"
    HA_BASE="http://127.0.0.1:${HA_PORT}"
    return 0
  fi
  _rhp_why=$(cat "${TMPDIR:-/tmp}/ga-ha-port.err" 2>/dev/null)
  show_verdict "$1" "Home Assistant port resolvable (ha core info: port, else Core version)" 1 \
    "${_rhp_why:-ha_port.sh not found next to test_helpers.sh}"
  HA_PORT="UNRESOLVED"
  HA_BASE="http://127.0.0.1:UNRESOLVED-PORT"
  return 1
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
