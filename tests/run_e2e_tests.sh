#!/usr/bin/env bash
# run_e2e_tests.sh — End-to-end Playwright tests for GA OS
#
# Usage:
#   tests/run_e2e_tests.sh --ssh root@<ip>
#   tests/run_e2e_tests.sh --runner <N>
#
# Options:
#   --port PORT              SSH port (default: 22222)
#   --admin-user USER        HA admin username (default: admin)
#   --admin-pass PASS        HA admin password — enables dashboard tests
#   --token TOKEN            HA long-lived access token — alternative to password
#   --project NAME           Playwright project: desktop|mobile-ios|mobile-android
#                            Default: all three projects
#   --suite FILE             Run a specific test file, e.g.: ga-setup, dashboard, onboarding
#   --reset-onboarding       Enable destructive onboarding flow tests (RESET_ONBOARDING=1)
#   --headed                 Run with visible browser (useful for debugging)
#   -h, --help               Show this help
#
# Examples:
#   # Basic smoke test (no auth needed):
#   tests/run_e2e_tests.sh --ssh root@<ip>
#
#   # Full test including dashboard:
#   tests/run_e2e_tests.sh --ssh root@<ip> --admin-pass changeme
#
#   # Mobile-only:
#   tests/run_e2e_tests.sh --ssh root@<ip> --project mobile-ios
#
#   # Destructive onboarding flow tests:
#   tests/run_e2e_tests.sh --ssh root@<ip> --admin-pass changeme --reset-onboarding
#
#   # Runner-based (VLAN device, runner 3 = 192.168.103.100):
#   tests/run_e2e_tests.sh --runner 3 --admin-pass changeme

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$SCRIPT_DIR/e2e"
SSH_KEY="$HOME/.ssh/ha-ihost.pem"   # was "~/..." in quotes, which never expands

usage() {
  sed -n '3,38p' "$0" | sed 's/^# //' | sed 's/^#//'
  exit 1
}

MODE=""
DEVICE_IP=""
SSH_PORT="22222"
HA_ADMIN_USER="admin"
HA_ADMIN_PASS=""
HA_TOKEN=""
PROJECT_ARGS=()
SUITE_ARG=""
HEADED=""
RESET_ONBOARDING=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh)
      MODE="ssh"
      DEVICE_IP="${2##*@}"   # strip user@ prefix
      shift 2
      ;;
    --runner)
      MODE="runner"
      DEVICE_IP="192.168.$((100 + $2)).100"
      shift 2
      ;;
    --port)             SSH_PORT="$2";       shift 2 ;;
    --admin-user)       HA_ADMIN_USER="$2";  shift 2 ;;
    --admin-pass)       HA_ADMIN_PASS="$2";  shift 2 ;;
    --token)            HA_TOKEN="$2";       shift 2 ;;
    --project)          PROJECT_ARGS=(--project "$2"); shift 2 ;;
    --suite)            SUITE_ARG="tests/$2.spec.ts"; shift 2 ;;
    --headed)           HEADED="--headed";   shift ;;
    --reset-onboarding) RESET_ONBOARDING="1"; shift ;;
    -h|--help)          usage ;;
    *) echo "Unknown option: $1"; echo ""; usage ;;
  esac
done

[[ -z "$MODE" ]] && { echo "ERROR: Specify --ssh root@<ip> or --runner N"; echo ""; usage; }

# Install Node dependencies and Playwright browsers if needed
if [[ ! -d "$E2E_DIR/node_modules" ]]; then
  echo "Installing Playwright dependencies..."
  cd "$E2E_DIR"
  npm ci
  npx playwright install chromium --with-deps
  cd - >/dev/null
fi

# Export env vars consumed by Playwright fixtures and tests
export DEVICE_IP="$DEVICE_IP"
export DEVICE_URL="http://${DEVICE_IP}:8123"

# Two whole suites skipped on every run because the runner never set the URL
# they gate on, although it already knew both — measured 2026-09-07 against a
# canary: 27 ga-manager-panel tests ("GA_PANEL_URL required") and 6 reverse-proxy
# tests ("CADDY_URL not set") out of 127 skips. The panel is the ga_manager
# add-on on port 8099 of the same device; the public URL is Core's own
# external_url, read over the SSH access the suite has anyway. An explicit
# environment value still wins, and a device without an external_url simply
# leaves CADDY_URL unset, which is the existing (skip) behaviour.
export GA_PANEL_URL="${GA_PANEL_URL:-http://${DEVICE_IP}:8099}"
if [[ -z "${CADDY_URL:-}" ]]; then
  _ext="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 -i "${SSH_KEY/#\~/$HOME}" -p "$SSH_PORT" "root@${DEVICE_IP}" \
            "sed -n 's/^  external_url: *\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p' /mnt/data/supervisor/homeassistant/configuration.yaml" \
            2>/dev/null | head -1 || true)"
  [[ "$_ext" == https://* ]] && export CADDY_URL="$_ext"
fi
# The panel suite also authenticates with the add-on's own Bearer token
# (/data/auth.token inside the ga_manager container, mode 0600). Read into the
# environment only — never echoed, never on a command line of a child process
# other than ssh's stdout. An explicit GA_PANEL_TOKEN still wins.
if [[ -z "${GA_PANEL_TOKEN:-}" ]]; then
  _tok="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 -i "${SSH_KEY/#\~/$HOME}" -p "$SSH_PORT" "root@${DEVICE_IP}" \
            'docker exec "$(docker ps -q --filter name=ga_manager | head -1)" cat /data/auth.token' \
            2>/dev/null | tr -d '\r\n' || true)"
  [[ ${#_tok} -ge 16 ]] && export GA_PANEL_TOKEN="$_tok"
  unset _tok
fi
export SSH_KEY="$SSH_KEY"
export SSH_PORT="$SSH_PORT"
export HA_ADMIN_USER="$HA_ADMIN_USER"
[[ -n "$HA_ADMIN_PASS"    ]] && export HA_ADMIN_PASS
[[ -n "$HA_TOKEN"         ]] && export HA_TOKEN
[[ -n "$RESET_ONBOARDING" ]] && export RESET_ONBOARDING="1"

AUTH_DESC="none (dashboard tests will skip)"
[[ -n "$HA_TOKEN"     ]] && AUTH_DESC="long-lived token"
[[ -n "$HA_ADMIN_PASS" ]] && AUTH_DESC="password (${HA_ADMIN_USER})"

# Which tree is this? A suite run from a checkout behind origin/master reports
# failures that were fixed weeks ago as work to do — on 2026-09-07 a run from a
# tree 25 commits behind reported 41 failures; the same suite from the current
# tree reported 1. The number is printed where it will actually be read: the
# header. It does not fail the run, because a branch under test is legitimately
# ahead or behind; it makes "behind" impossible to miss.
_tree="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
_behind="$(git -C "$SCRIPT_DIR" fetch -q origin 2>/dev/null; git -C "$SCRIPT_DIR" rev-list --count HEAD..origin/master 2>/dev/null || echo '?')"
_tree_note="tree ${_tree}"
[[ "${_behind}" =~ ^[0-9]+$ ]] && [[ "${_behind}" -gt 0 ]] && _tree_note="tree ${_tree} — ${_behind} COMMITS BEHIND origin/master; failures may already be fixed"

echo "=============================================="
echo "  GA OS E2E Tests"
echo "  Tree:    ${_tree_note}"
echo "  Device:  http://${DEVICE_IP}:8123"
echo "  Panel:   ${GA_PANEL_URL} (token: $([[ -n "${GA_PANEL_TOKEN:-}" ]] && echo present || echo MISSING — panel suite skips))"
echo "  Public:  ${CADDY_URL:-(no external_url on device — reverse-proxy public tests skip)}"
echo "  Auth:    ${AUTH_DESC}"
echo "  Reset:   $([ -n "$RESET_ONBOARDING" ] && echo "YES — destructive onboarding tests enabled" || echo "no (onboarding tests skipped)")"
echo "=============================================="
echo ""

cd "$E2E_DIR"
set +e
npx playwright test \
  "${PROJECT_ARGS[@]}" \
  ${HEADED} \
  ${SUITE_ARG} \
  2>&1
EXIT_CODE=$?
set -e

# Parse and display the summary. The parser lives in its own file with its own
# fixtures (tests/e2e/test_summarize_results.sh) because the version that was
# inline here could not report a failure: it compared Playwright's outcome
# field, which holds expected/unexpected/skipped, against "passed"/"failed".
SUMMARY="$E2E_DIR/summarize_results.py"
if [[ -f test-results/results.json ]] && command -v python3 &>/dev/null; then
  if [[ ! -x "$SUMMARY" ]]; then
    echo "E2E: summariser missing at $SUMMARY — cannot report the result" >&2
    exit 2
  fi
  set +e
  python3 "$SUMMARY" test-results/results.json
  SUMMARY_CODE=$?
  set -e
  # The two must agree. If Playwright failed, the run failed, whatever the
  # report says; if the report says failures and Playwright exited 0, that
  # disagreement is itself a defect and must not be swallowed.
  if [[ "$EXIT_CODE" -eq 0 && "$SUMMARY_CODE" -ne 0 ]]; then
    echo "E2E: Playwright exited 0 but the report says otherwise — failing on the report" >&2
    EXIT_CODE="$SUMMARY_CODE"
  fi
else
  echo "E2E: no test-results/results.json — no result was produced" >&2
  [[ "$EXIT_CODE" -eq 0 ]] && EXIT_CODE=2
fi

exit "$EXIT_CODE"
