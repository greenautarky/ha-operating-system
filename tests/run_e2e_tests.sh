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
SSH_KEY="~/.ssh/ha-ihost.pem"

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
export SSH_KEY="$SSH_KEY"
export SSH_PORT="$SSH_PORT"
export HA_ADMIN_USER="$HA_ADMIN_USER"
[[ -n "$HA_ADMIN_PASS"    ]] && export HA_ADMIN_PASS
[[ -n "$HA_TOKEN"         ]] && export HA_TOKEN
[[ -n "$RESET_ONBOARDING" ]] && export RESET_ONBOARDING="1"

AUTH_DESC="none (dashboard tests will skip)"
[[ -n "$HA_TOKEN"     ]] && AUTH_DESC="long-lived token"
[[ -n "$HA_ADMIN_PASS" ]] && AUTH_DESC="password (${HA_ADMIN_USER})"

echo "=============================================="
echo "  GA OS E2E Tests"
echo "  Device:  http://${DEVICE_IP}:8123"
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

# Parse and display summary from JSON report
if [[ -f test-results/results.json ]] && command -v python3 &>/dev/null; then
  python3 - <<'PYEOF'
import json, sys
try:
    with open("test-results/results.json") as f:
        data = json.load(f)
    def walk(node):
        counts = {"passed": 0, "failed": 0, "skipped": 0}
        for spec in node.get("specs", []):
            for t in spec.get("tests", []):
                s = t.get("status", "unknown")
                if s in counts:
                    counts[s] += 1
        for suite in node.get("suites", []):
            sub = walk(suite)
            for k in counts:
                counts[k] += sub[k]
        return counts
    c = walk(data)
    print(f"\n==============================================")
    print(f"  E2E: {c['passed']} passed, {c['failed']} failed, {c['skipped']} skipped")
    if c['failed'] == 0:
        print("  Result: ALL PASS")
    else:
        print(f"  Result: {c['failed']} FAILURES")
    print("==============================================")
except Exception as e:
    pass
PYEOF
fi

exit "$EXIT_CODE"
