#!/bin/sh
# run_all.sh - Execute GA test suites on the device
# This script runs directly on the device (via SSH or serial).
#
# Usage (on device):
#   sh /tmp/ga_tests/run_all.sh                    # all device tests
#   sh /tmp/ga_tests/run_all.sh crash_detection     # specific suites
#   sh /tmp/ga_tests/run_all.sh --category device   # by category
#   sh /tmp/ga_tests/run_all.sh --category emu      # emulation-safe tests
#
# Categories:
#   build  - runs during ga_build.sh (use run_build_tests.sh instead)
#   emu    - safe to run in QEMU/emulation (no real hardware needed)
#   device - needs real iHost hardware, network, Docker, HA running
#   all    - all device+emu tests (default)
#
# Exit code = total number of failures (0 = all pass)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Test suites by category
SUITES_EMU="environment crash_detection boot_timing disk_guard"
SUITES_DEVICE="telemetry network ping config_verify onboarding tailscale watchdog stress"
SUITES_ALL="crash_detection telemetry environment network ping boot_timing disk_guard watchdog config_verify stress onboarding tailscale"

# Parse arguments
CATEGORY=""
SUITES=""
for arg in "$@"; do
  case "$arg" in
    --category) CATEGORY="next" ;;
    *)
      if [ "$CATEGORY" = "next" ]; then
        case "$arg" in
          emu)    SUITES="$SUITES_EMU" ;;
          device) SUITES="$SUITES_DEVICE" ;;
          all)    SUITES="$SUITES_ALL" ;;
          *)      echo "Unknown category: $arg (use: emu, device, all)"; exit 1 ;;
        esac
        CATEGORY=""
      else
        SUITES="${SUITES:+$SUITES }$arg"
      fi
      ;;
  esac
done
SUITES="${SUITES:-$SUITES_ALL}"

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
EXIT=0

echo "=============================================="
echo "  GA OS Test Runner"
echo "  Device: $(hostname 2>/dev/null || echo unknown)"
echo "  Date:   $(date 2>/dev/null)"
echo "  Suites: $SUITES"
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
