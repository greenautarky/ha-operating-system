#!/bin/bash
# generate-report.sh — Generate a combined HTML test report
#
# Combines results from:
#   1. Build tests (from build-report.html or build log)
#   2. Device tests (from run_all.sh JSON output)
#   3. E2E tests (from Playwright JSON results)
#
# Usage:
#   ./tests/generate-report.sh [options]
#
#   --build-report PATH    Path to build-report.html (optional)
#   --device-output PATH   Path to device test output (run_all.sh stdout)
#   --e2e-results PATH     Path to Playwright results JSON
#   --output PATH          Output HTML file (default: test-report.html)
#   --device-ip IP         Device IP (for report metadata)
#   --build-id ID          Build ID (for report metadata)

set -euo pipefail

BUILD_REPORT=""
DEVICE_OUTPUT=""
E2E_RESULTS=""
OUTPUT="test-report.html"
DEVICE_IP="${DEVICE_IP:-unknown}"
BUILD_ID="${BUILD_ID:-$(date '+%Y%m%d%H%M%S')}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --build-report)  BUILD_REPORT="$2"; shift 2 ;;
    --device-output) DEVICE_OUTPUT="$2"; shift 2 ;;
    --e2e-results)   E2E_RESULTS="$2"; shift 2 ;;
    --output)        OUTPUT="$2"; shift 2 ;;
    --device-ip)     DEVICE_IP="$2"; shift 2 ;;
    --build-id)      BUILD_ID="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Parse device test results ---
DEVICE_SUITES=""
DEVICE_TOTAL_PASS=0
DEVICE_TOTAL_FAIL=0
DEVICE_TOTAL_SKIP=0
DEVICE_ROWS=""

if [[ -f "$DEVICE_OUTPUT" ]]; then
  while IFS= read -r line; do
    suite=$(echo "$line" | jq -r '.suite // empty' 2>/dev/null || true)
    [[ -z "$suite" ]] && continue
    pass=$(echo "$line" | jq -r '.pass // 0' 2>/dev/null)
    fail=$(echo "$line" | jq -r '.fail // 0' 2>/dev/null)
    skip=$(echo "$line" | jq -r '.skip // 0' 2>/dev/null)
    total=$((pass + fail + skip))
    DEVICE_TOTAL_PASS=$((DEVICE_TOTAL_PASS + pass))
    DEVICE_TOTAL_FAIL=$((DEVICE_TOTAL_FAIL + fail))
    DEVICE_TOTAL_SKIP=$((DEVICE_TOTAL_SKIP + skip))
    if [[ "$fail" -gt 0 ]]; then
      status_class="fail"
      status_text="FAIL"
    elif [[ "$skip" -gt 0 ]] && [[ "$pass" -eq 0 ]]; then
      status_class="skip"
      status_text="SKIP"
    else
      status_class="pass"
      status_text="PASS"
    fi
    DEVICE_ROWS="${DEVICE_ROWS}<tr><td>${suite}</td><td>${pass}</td><td class='${status_class}'>${fail}</td><td>${skip}</td><td>${total}</td><td class='${status_class}'>${status_text}</td></tr>"
  done < <(grep '{"suite"' "$DEVICE_OUTPUT" 2>/dev/null || true)
fi

# --- Parse E2E results ---
E2E_PASS=0
E2E_FAIL=0
E2E_SKIP=0
E2E_ROWS=""

if [[ -f "$E2E_RESULTS" ]]; then
  # Playwright JSON reporter uses stats.expected/unexpected/skipped
  E2E_PASS=$(jq '.stats.expected // 0' "$E2E_RESULTS" 2>/dev/null || echo 0)
  E2E_FAIL=$(jq '.stats.unexpected // 0' "$E2E_RESULTS" 2>/dev/null || echo 0)
  E2E_SKIP=$(jq '.stats.skipped // 0' "$E2E_RESULTS" 2>/dev/null || echo 0)

  # Build per-suite rows from top-level suites
  while IFS= read -r spec; do
    file=$(echo "$spec" | jq -r '.title // "unknown"')
    s_pass=$(echo "$spec" | jq '[.suites[]?.specs[]?.tests[]? | select(.status == "expected")] | length')
    s_fail=$(echo "$spec" | jq '[.suites[]?.specs[]?.tests[]? | select(.status == "unexpected")] | length')
    s_skip=$(echo "$spec" | jq '[.suites[]?.specs[]?.tests[]? | select(.status == "skipped")] | length')
    s_total=$((s_pass + s_fail + s_skip))
    [[ "$s_total" -eq 0 ]] && continue
    if [[ "$s_fail" -gt 0 ]]; then
      sc="fail"; st="FAIL"
    else
      sc="pass"; st="PASS"
    fi
    E2E_ROWS="${E2E_ROWS}<tr><td>${file}</td><td>${s_pass}</td><td class='${sc}'>${s_fail}</td><td>${s_skip}</td><td>${s_total}</td><td class='${sc}'>${st}</td></tr>"
  done < <(jq -c '.suites[]?' "$E2E_RESULTS" 2>/dev/null || true)
fi

# --- Parse build test results from build report ---
BUILD_PASS=0
BUILD_FAIL=0
BUILD_SKIP=0

if [[ -f "$BUILD_REPORT" ]]; then
  BUILD_PASS=$(grep -oP '\d+(?= PASS)' "$BUILD_REPORT" | head -1 || echo 0)
  BUILD_FAIL=$(grep -oP '\d+(?= FAIL)' "$BUILD_REPORT" | head -1 || echo 0)
  BUILD_SKIP=$(grep -oP '\d+(?= SKIP)' "$BUILD_REPORT" | head -1 || echo 0)
fi

# --- Totals ---
TOTAL_PASS=$((BUILD_PASS + DEVICE_TOTAL_PASS + E2E_PASS))
TOTAL_FAIL=$((BUILD_FAIL + DEVICE_TOTAL_FAIL + E2E_FAIL))
TOTAL_SKIP=$((BUILD_SKIP + DEVICE_TOTAL_SKIP + E2E_SKIP))
TOTAL=$((TOTAL_PASS + TOTAL_FAIL + TOTAL_SKIP))

if [[ "$TOTAL_FAIL" -gt 0 ]]; then
  OVERALL="FAIL"
  OVERALL_CLASS="fail"
elif [[ "$TOTAL_PASS" -eq 0 ]]; then
  OVERALL="NO DATA"
  OVERALL_CLASS="skip"
else
  OVERALL="PASS"
  OVERALL_CLASS="pass"
fi

# --- Generate HTML ---
cat > "$OUTPUT" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>GA OS Test Report — ${BUILD_ID}</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 1000px; margin: 40px auto; padding: 0 20px; color: #333; background: #fafafa; }
  h1 { color: #2e7d32; border-bottom: 3px solid #2e7d32; padding-bottom: 10px; }
  h2 { color: #1b5e20; margin-top: 30px; }
  table { border-collapse: collapse; width: 100%; margin: 10px 0; }
  th, td { padding: 8px 12px; text-align: left; border: 1px solid #ddd; }
  th { background: #e8f5e9; }
  .pass { color: #2e7d32; font-weight: bold; }
  .fail { color: #c62828; font-weight: bold; }
  .skip { color: #f57f17; }
  .mono { font-family: 'Fira Code', monospace; font-size: 0.9em; }
  .badge { display: inline-block; padding: 6px 16px; border-radius: 4px; color: white; font-weight: bold; font-size: 1.1em; }
  .badge-pass { background: #2e7d32; }
  .badge-fail { background: #c62828; }
  .badge-skip { background: #f57f17; }
  .summary-grid { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 15px; margin: 20px 0; }
  .summary-card { background: white; border: 1px solid #ddd; border-radius: 8px; padding: 15px; text-align: center; }
  .summary-card h3 { margin: 0 0 8px; font-size: 0.9em; color: #666; }
  .summary-card .number { font-size: 2em; font-weight: bold; }
  .footer { margin-top: 40px; padding-top: 15px; border-top: 1px solid #ddd; color: #999; font-size: 0.85em; }
  .overall { text-align: center; margin: 20px 0; }
</style>
</head>
<body>
<h1>GA OS Test Report</h1>

<div class="overall">
  <span class="badge badge-${OVERALL_CLASS}">${OVERALL}</span>
</div>

<table>
<tr><td>Build ID</td><td class="mono">${BUILD_ID}</td></tr>
<tr><td>Device</td><td class="mono">${DEVICE_IP}</td></tr>
<tr><td>Date</td><td>$(date '+%Y-%m-%d %H:%M:%S')</td></tr>
</table>

<div class="summary-grid">
  <div class="summary-card">
    <h3>Build Tests</h3>
    <div class="number pass">${BUILD_PASS}</div>
    <div>${BUILD_FAIL} fail / ${BUILD_SKIP} skip</div>
  </div>
  <div class="summary-card">
    <h3>Device Tests</h3>
    <div class="number pass">${DEVICE_TOTAL_PASS}</div>
    <div>${DEVICE_TOTAL_FAIL} fail / ${DEVICE_TOTAL_SKIP} skip</div>
  </div>
  <div class="summary-card">
    <h3>E2E Tests</h3>
    <div class="number pass">${E2E_PASS}</div>
    <div>${E2E_FAIL} fail / ${E2E_SKIP} skip</div>
  </div>
</div>

<h2>Totals</h2>
<table>
<tr><th>Category</th><th>Pass</th><th>Fail</th><th>Skip</th><th>Total</th></tr>
<tr><td>Build</td><td class="pass">${BUILD_PASS}</td><td class="fail">${BUILD_FAIL}</td><td>${BUILD_SKIP}</td><td>$((BUILD_PASS + BUILD_FAIL + BUILD_SKIP))</td></tr>
<tr><td>Device</td><td class="pass">${DEVICE_TOTAL_PASS}</td><td class="fail">${DEVICE_TOTAL_FAIL}</td><td>${DEVICE_TOTAL_SKIP}</td><td>$((DEVICE_TOTAL_PASS + DEVICE_TOTAL_FAIL + DEVICE_TOTAL_SKIP))</td></tr>
<tr><td>E2E (Playwright)</td><td class="pass">${E2E_PASS}</td><td class="fail">${E2E_FAIL}</td><td>${E2E_SKIP}</td><td>$((E2E_PASS + E2E_FAIL + E2E_SKIP))</td></tr>
<tr style="font-weight:bold; background:#f5f5f5;"><td>Total</td><td class="pass">${TOTAL_PASS}</td><td class="fail">${TOTAL_FAIL}</td><td>${TOTAL_SKIP}</td><td>${TOTAL}</td></tr>
</table>

$(if [[ -n "$DEVICE_ROWS" ]]; then
cat <<DEVEOF
<h2>Device Tests (by suite)</h2>
<table>
<tr><th>Suite</th><th>Pass</th><th>Fail</th><th>Skip</th><th>Total</th><th>Status</th></tr>
${DEVICE_ROWS}
</table>
DEVEOF
fi)

$(if [[ -n "$E2E_ROWS" ]]; then
cat <<E2EEOF
<h2>E2E Tests (by spec file)</h2>
<table>
<tr><th>Spec</th><th>Pass</th><th>Fail</th><th>Skip</th><th>Total</th><th>Status</th></tr>
${E2E_ROWS}
</table>
E2EEOF
fi)

$(if [[ -f "$DEVICE_OUTPUT" ]]; then
  FAIL_LINES=$(grep -E '^\s*(FAIL|✘)' "$DEVICE_OUTPUT" 2>/dev/null || true)
  if [[ -n "$FAIL_LINES" ]]; then
cat <<FAILEOF
<h2>Failed Tests (Device)</h2>
<pre>$(echo "$FAIL_LINES")</pre>
FAILEOF
  fi
fi)

<div class="footer">
  Generated by tests/generate-report.sh | GreenAutarky GmbH | $(date -Iseconds)
  <br>Playwright HTML report: <a href="tests/e2e/playwright-report/index.html">tests/e2e/playwright-report/index.html</a>
</div>
</body>
</html>
HTMLEOF

echo "Report generated: $OUTPUT"
echo "  Build:  ${BUILD_PASS} pass / ${BUILD_FAIL} fail / ${BUILD_SKIP} skip"
echo "  Device: ${DEVICE_TOTAL_PASS} pass / ${DEVICE_TOTAL_FAIL} fail / ${DEVICE_TOTAL_SKIP} skip"
echo "  E2E:    ${E2E_PASS} pass / ${E2E_FAIL} fail / ${E2E_SKIP} skip"
echo "  TOTAL:  ${TOTAL_PASS} pass / ${TOTAL_FAIL} fail / ${TOTAL_SKIP} skip"
