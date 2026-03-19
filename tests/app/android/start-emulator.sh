#!/usr/bin/env bash
# android/start-emulator.sh — Start Android emulator and wait for boot
#
# Usage:
#   tests/app/android/start-emulator.sh [AVD_NAME]
#
# Exits 0 immediately if an emulator is already running.
# Waits up to 120s for boot (sys.boot_completed=1).
#
# Environment:
#   ANDROID_HOME  — Android SDK path (default: ~/Android/Sdk)
#   AVD_NAME      — AVD to start (default: ga-test, first positional arg overrides)

set -euo pipefail

ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
AVD_NAME="${1:-${AVD_NAME:-ga-test}}"
TIMEOUT="${BOOT_TIMEOUT:-120}"

EMULATOR="$ANDROID_HOME/emulator/emulator"
ADB="$ANDROID_HOME/platform-tools/adb"

[[ -x "$EMULATOR" ]] || { echo "ERROR: emulator not found at $ANDROID_HOME"; exit 1; }
[[ -x "$ADB" ]]      || { echo "ERROR: adb not found at $ANDROID_HOME"; exit 1; }

# ── Already running? ──────────────────────────────────────────────────────────

if "$ADB" devices 2>/dev/null | grep -q 'emulator.*device'; then
  echo "[emulator] already running — skipping start"
  exit 0
fi

# ── Launch emulator ───────────────────────────────────────────────────────────

echo "[emulator] starting AVD: $AVD_NAME"
nohup "$EMULATOR" \
  -avd "$AVD_NAME" \
  -no-audio \
  -no-window \
  -gpu swiftshader_indirect \
  -no-snapshot-save \
  > /tmp/ga-emulator.log 2>&1 &

EMULATOR_PID=$!
echo "[emulator] PID $EMULATOR_PID (log: /tmp/ga-emulator.log)"

# ── Wait for boot ─────────────────────────────────────────────────────────────

echo "[emulator] waiting for boot (up to ${TIMEOUT}s)..."
ELAPSED=0

while [[ $ELAPSED -lt $TIMEOUT ]]; do
  BOOT_PROP=$("$ADB" -e shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n' || true)

  if [[ "$BOOT_PROP" == "1" ]]; then
    # Unlock the screen (simulates a swipe-up)
    "$ADB" -e shell input keyevent 82 2>/dev/null || true
    sleep 3  # Extra settling time for system services
    echo "[emulator] ready"
    exit 0
  fi

  sleep 3
  ELAPSED=$((ELAPSED + 3))
done

echo "ERROR: emulator did not boot within ${TIMEOUT}s"
echo "       Check /tmp/ga-emulator.log for errors"
exit 1
