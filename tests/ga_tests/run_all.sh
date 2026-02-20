#!/bin/sh
# run_all.sh - Execute all GA test suites on the device
# This script runs directly on the device (via SSH or serial).
#
# Usage (on device):
#   sh /tmp/ga_tests/run_all.sh
#   sh /tmp/ga_tests/run_all.sh crash_detection network   # run specific suites
#
# Exit code = total number of failures (0 = all pass)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ALL_SUITES="crash_detection telemetry environment network ping boot_timing disk_guard watchdog config_verify"
SUITES="${*:-$ALL_SUITES}"

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
EXIT=0

echo "=============================================="
echo "  GA OS Test Runner"
echo "  Device: $(hostname 2>/dev/null || echo unknown)"
echo "  Date:   $(date 2>/dev/null)"
echo "=============================================="

for suite in $SUITES; do
  test_script="$SCRIPT_DIR/$suite/test.sh"
  if [ ! -f "$test_script" ]; then
    echo ""
    echo "=== $suite ==="
    echo "  SKIP  (no test.sh found)"
    continue
  fi

  # Run in subshell, capture output
  output=$(sh "$test_script" 2>&1)
  rc=$?
  echo "$output"

  # Extract counts from JSON line emitted by suite_end
  json=$(echo "$output" | grep '^{"suite"' | tail -1)
  if [ -n "$json" ]; then
    p=$(echo "$json" | sed 's/.*"pass":\([0-9]*\).*/\1/')
    f=$(echo "$json" | sed 's/.*"fail":\([0-9]*\).*/\1/')
    s=$(echo "$json" | sed 's/.*"skip":\([0-9]*\).*/\1/')
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + f))
    TOTAL_SKIP=$((TOTAL_SKIP + s))
  fi

  [ "$rc" -ne 0 ] && EXIT=$((EXIT + rc))
done

TOTAL=$((TOTAL_PASS + TOTAL_FAIL + TOTAL_SKIP))

echo "=============================================="
echo "  TOTAL: ${TOTAL_PASS} passed, ${TOTAL_FAIL} failed, ${TOTAL_SKIP} skipped (${TOTAL} tests)"
if [ "$TOTAL_FAIL" -eq 0 ]; then
  echo "  Result: ALL PASS"
else
  echo "  Result: ${TOTAL_FAIL} FAILURES"
fi
echo "=============================================="

exit $EXIT
