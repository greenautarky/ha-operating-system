#!/usr/bin/env bash
# run_app_tests.sh — Optional Android app tests for GA OS (EXPERIMENTAL)
#
# Tests the HA Companion app onboarding and login flows via Appium + WebDriverIO.
# Supports two targets: a real iHost device, or local HA Core in Docker.
#
# Usage:
#   RUN_APP_TESTS=1 tests/run_app_tests.sh --ssh root@<ip>     # real iHost
#   RUN_APP_TESTS=1 tests/run_app_tests.sh --runner <N>        # VLAN runner
#   RUN_APP_TESTS=1 tests/run_app_tests.sh --local             # local Docker HA
#
# Options:
#   --local              Use local HA Core in Docker (http://10.0.2.2:8123)
#                        No SSH needed — resets via docker exec on host.
#                        Start HA first: tests/app/android/start-ha-local.sh
#   --port PORT          SSH port for device access (default: 22222)
#   --admin-user USER    HA admin username (default: admin)
#   --admin-pass PASS    HA admin password (required for login tests)
#   --avd NAME           Android AVD name (default: ga-test)
#   --apk PATH           Path to HA Companion APK (default: tests/app/android/ha-companion.apk)
#   --suite NAME         Test suite: onboarding | login | all (default: all)
#   --no-avd             Skip emulator start (use an already-running emulator)
#   --setup              Run android/setup.sh before tests
#   -h, --help           Show this help
#
# Prerequisites (run once):
#   tests/app/android/setup.sh
#
# Guard:
#   RUN_APP_TESTS=1 must be set. Without it, the script exits 0 (skipped) so it
#   doesn't block the main test pipeline when called unconditionally.
#
# Examples:
#   # Real iHost — first-time setup + run:
#   RUN_APP_TESTS=1 tests/run_app_tests.sh --ssh root@&lt;ip&gt; --admin-pass changeme --setup
#
#   # Real iHost — emulator already running:
#   RUN_APP_TESTS=1 tests/run_app_tests.sh --ssh root@&lt;ip&gt; --admin-pass changeme --no-avd
#
#   # Local Docker HA Core (no physical device needed):
#   tests/app/android/start-ha-local.sh          # start HA in Docker first
#   RUN_APP_TESTS=1 tests/run_app_tests.sh --local --admin-pass changeme --no-avd
#
#   # Via runner infrastructure (VLAN, runner 3 = 192.168.103.100):
#   RUN_APP_TESTS=1 tests/run_app_tests.sh --runner 3 --admin-pass changeme

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR/app"

# ── Guard — skip gracefully if not opted in ───────────────────────────────────

if [[ -z "${RUN_APP_TESTS:-}" ]]; then
  echo "App tests skipped (set RUN_APP_TESTS=1 to enable)"
  exit 0
fi

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  sed -n '3,47p' "$0" | sed 's/^# //' | sed 's/^#//'
  exit 1
}

# ── Argument parsing ──────────────────────────────────────────────────────────

MODE=""
DEVICE_IP=""
LOCAL_MODE=false
SSH_PORT="22222"
HA_ADMIN_USER="admin"
HA_ADMIN_PASS=""
AVD_NAME="${AVD_NAME:-ga-test}"
APK_PATH="${APK_PATH:-$APP_DIR/android/ha-companion.apk}"
SUITE="all"
START_AVD=true
RUN_SETUP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)       MODE="local"; LOCAL_MODE=true; shift ;;
    --ssh)         MODE="ssh";    DEVICE_IP="${2##*@}";                    shift 2 ;;
    --runner)      MODE="runner"; DEVICE_IP="192.168.$((100 + $2)).100";   shift 2 ;;
    --port)        SSH_PORT="$2";       shift 2 ;;
    --admin-user)  HA_ADMIN_USER="$2";  shift 2 ;;
    --admin-pass)  HA_ADMIN_PASS="$2";  shift 2 ;;
    --avd)         AVD_NAME="$2";       shift 2 ;;
    --apk)         APK_PATH="$2";       shift 2 ;;
    --suite)       SUITE="$2";          shift 2 ;;
    --no-avd)      START_AVD=false;     shift ;;
    --setup)       RUN_SETUP=true;      shift ;;
    -h|--help)     usage ;;
    *) echo "Unknown option: $1"; echo ""; usage ;;
  esac
done

[[ -z "$MODE" ]] && { echo "ERROR: Specify --local, --ssh root@<ip>, or --runner N"; echo ""; usage; }

# ── Optional one-time setup ───────────────────────────────────────────────────

if $RUN_SETUP; then
  echo "Running setup..."
  "$APP_DIR/android/setup.sh"
  echo ""
fi

# ── Verify APK ────────────────────────────────────────────────────────────────

# Fall back to release APK if debug isn't available yet (native UI tests still run)
if [[ ! -f "$APK_PATH" ]]; then
  RELEASE_APK="$APP_DIR/android/ha-companion-release.apk"
  if [[ -f "$RELEASE_APK" ]]; then
    echo "NOTE: Debug APK not found — falling back to release APK (WebView tests will fail)"
    echo "      Save debug build as: $APK_PATH"
    APK_PATH="$RELEASE_APK"
  else
    echo "ERROR: APK not found at $APK_PATH"
    echo ""
    echo "Run setup:  tests/app/android/setup.sh"
    echo "Or set:     --apk /path/to/ha-companion-debug.apk"
    exit 1
  fi
fi

# ── Local mode: verify Docker HA is running ───────────────────────────────────

if $LOCAL_MODE; then
  HA_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 \
    "http://localhost:${HA_PORT:-8123}/api/" 2>/dev/null || echo "000")
  if [[ "$HA_STATUS" != "200" && "$HA_STATUS" != "401" ]]; then
    echo "ERROR: HA Core not responding at http://localhost:${HA_PORT:-8123} (HTTP $HA_STATUS)"
    echo ""
    echo "Start it first:"
    echo "  tests/app/android/start-ha-local.sh"
    exit 1
  fi
fi

# ── Start emulator ────────────────────────────────────────────────────────────

if $START_AVD; then
  "$APP_DIR/android/start-emulator.sh" "$AVD_NAME"
fi

# ── Install npm dependencies ──────────────────────────────────────────────────

if [[ ! -d "$APP_DIR/node_modules" ]]; then
  echo "Installing dependencies..."
  cd "$APP_DIR"
  npm ci
  cd - > /dev/null
fi

# ── Export env vars ───────────────────────────────────────────────────────────

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

export RUN_APP_TESTS=1
export SSH_PORT="$SSH_PORT"
export HA_ADMIN_USER="$HA_ADMIN_USER"
export AVD_NAME="$AVD_NAME"
export APK_PATH="$APK_PATH"

if $LOCAL_MODE; then
  export LOCAL_MODE=1
  export DEVICE_URL="http://10.0.2.2:${HA_PORT:-8123}"
  # HOST_URL is derived from LOCAL_MODE in fixtures/device.ts
else
  export DEVICE_IP="$DEVICE_IP"
fi

[[ -n "$HA_ADMIN_PASS" ]] && export HA_ADMIN_PASS

# ── Print header ──────────────────────────────────────────────────────────────

if $LOCAL_MODE; then
  TARGET_DESC="local Docker HA (http://10.0.2.2:${HA_PORT:-8123})"
else
  TARGET_DESC="iHost device  http://${DEVICE_IP}:8123"
fi

AUTH_DESC="none (login tests will skip)"
[[ -n "$HA_ADMIN_PASS" ]] && AUTH_DESC="password (${HA_ADMIN_USER})"

echo "=============================================="
echo "  GA App Tests (EXPERIMENTAL)"
echo "  Target:  ${TARGET_DESC}"
echo "  Auth:    ${AUTH_DESC}"
echo "  AVD:     ${AVD_NAME}"
echo "  APK:     $(basename "$APK_PATH")"
echo "  Suite:   ${SUITE}"
echo "=============================================="
echo ""

# ── Resolve spec arg ──────────────────────────────────────────────────────────

case "$SUITE" in
  onboarding) SPEC_ARG="--spec tests/onboarding.spec.ts" ;;
  login)      SPEC_ARG="--spec tests/login.spec.ts" ;;
  all)        SPEC_ARG="" ;;
  *)
    echo "Unknown suite: $SUITE (use: onboarding, login, all)"
    exit 1
    ;;
esac

# ── Run tests ─────────────────────────────────────────────────────────────────

cd "$APP_DIR"
set +e
# shellcheck disable=SC2086
npx wdio run wdio.android.conf.ts $SPEC_ARG 2>&1
EXIT_CODE=$?
set -e

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=============================================="
if [[ $EXIT_CODE -eq 0 ]]; then
  echo "  App Tests: ALL PASS"
else
  echo "  App Tests: FAILURES DETECTED (exit $EXIT_CODE)"
  echo ""
  echo "  Troubleshooting:"
  echo "    - Check appium.log in tests/app/"
  echo "    - WebView tests require a debug APK (release APK won't work)"
  if $LOCAL_MODE; then
    echo "    - Check local HA: docker logs ha-local"
    echo "    - Verify reachable: curl http://localhost:${HA_PORT:-8123}/api/"
  else
    echo "    - Check device: curl http://${DEVICE_IP}:8123/api/"
  fi
fi
echo "=============================================="

exit "$EXIT_CODE"
