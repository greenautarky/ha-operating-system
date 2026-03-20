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
SUITES_DEVICE="health telemetry network ping config_verify onboarding tailscale watchdog stress idle_perf hardware"
SUITES_ALL="crash_detection health telemetry environment network ping boot_timing disk_guard watchdog config_verify stress idle_perf onboarding tailscale hardware"

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
SUITE_RESULTS=""

# Gather device info for report header
_hostname=$(hostname 2>/dev/null || echo "unknown")
_date=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date 2>/dev/null)
_build_id=$(cat /etc/ga-build-id 2>/dev/null || echo "unknown")
_ga_env=$(. /etc/ga-env.conf 2>/dev/null && echo "$GA_ENV" || echo "unknown")
_kernel=$(uname -r 2>/dev/null || echo "unknown")
_uptime=$(uptime 2>/dev/null | sed 's/.*up /up /' | sed 's/,.*load/ load/' || echo "unknown")
_mem_total=$(awk '/^MemTotal:/ {printf "%d MB", $2/1024}' /proc/meminfo 2>/dev/null || echo "unknown")
_ha_ver=$(docker inspect homeassistant 2>/dev/null | grep -o '"io.hass.version":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")

echo "=============================================="
echo "  GA OS Test Runner"
echo "  Host:     $_hostname"
echo "  Date:     $_date"
echo "  Build:    $_build_id"
echo "  Env:      $_ga_env"
echo "  Kernel:   $_kernel"
echo "  RAM:      $_mem_total"
echo "  HA Core:  $_ha_ver"
echo "  Uptime:   $_uptime"
echo "  Suites:   $SUITES"
echo "=============================================="

for suite in $SUITES; do
  test_script="$SCRIPT_DIR/$suite/test.sh"
  if [ ! -f "$test_script" ]; then
    echo ""
    echo "=== $suite ==="
    echo "  SKIP  (no test.sh found)"
    SUITE_RESULTS="${SUITE_RESULTS}${suite}|0|0|1|SKIP\n"
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
    if [ "$f" -gt 0 ]; then
      status="FAIL"
    else
      status="PASS"
    fi
    SUITE_RESULTS="${SUITE_RESULTS}${suite}|${p}|${f}|${s}|${status}\n"
  fi

  [ "$rc" -ne 0 ] && EXIT=$((EXIT + rc))
done

TOTAL=$((TOTAL_PASS + TOTAL_FAIL + TOTAL_SKIP))

echo ""
echo "=============================================="
echo "  TEST REPORT"
echo "=============================================="
echo ""
echo "  Device:   $_hostname ($_ga_env)"
echo "  Build:    $_build_id"
echo "  HA Core:  $_ha_ver"
echo "  Date:     $_date"
echo ""
echo "  Suite               Pass  Fail  Skip  Status"
echo "  ────────────────────────────────────────────"
printf "$SUITE_RESULTS" | while IFS='|' read -r name p f s st; do
  [ -z "$name" ] && continue
  printf "  %-20s %4s  %4s  %4s  %s\n" "$name" "$p" "$f" "$s" "$st"
done
echo "  ────────────────────────────────────────────"
printf "  %-20s %4s  %4s  %4s\n" "TOTAL" "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_SKIP"
echo ""
if [ "$TOTAL_FAIL" -eq 0 ]; then
  echo "  Result: ALL PASS ($TOTAL tests)"
else
  echo "  Result: ${TOTAL_FAIL} FAILURES ($TOTAL tests)"
fi
echo "=============================================="

exit $EXIT
