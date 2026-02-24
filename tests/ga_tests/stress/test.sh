#!/bin/sh
# Stress / stability test suite - runs ON the device
# Uses stress-ng to verify system stability under load.
# Default timeout is 30s per test for automated runs.
# Set STRESS_TIMEOUT=300 (or higher) for thorough testing.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Stress"

T="${STRESS_TIMEOUT:-30}"
# stress-ng needs a writable temp directory (rootfs is read-only)
TP="/tmp"

# --- Prerequisites ---

if ! command -v stress-ng >/dev/null 2>&1; then
  skip_test "STRESS-01" "stress-ng is installed" "stress-ng not found"
  skip_test "STRESS-02" "CPU stress" "stress-ng not found"
  skip_test "STRESS-03" "Memory stress" "stress-ng not found"
  skip_test "STRESS-04" "Disk I/O stress" "stress-ng not found"
  skip_test "STRESS-05" "Combined stress" "stress-ng not found"
  skip_test "STRESS-06" "Thermal check under load" "stress-ng not found"
  skip_test "STRESS-07" "Service recovery after OOM pressure" "stress-ng not found"
  skip_test "STRESS-08" "Fork bomb resilience" "stress-ng not found"
  skip_test "STRESS-09" "Telemetry under CPU load" "stress-ng not found"
  skip_test "STRESS-10" "24h soak test" "stress-ng not found"
  suite_end
  exit 0
fi

run_test "STRESS-01" "stress-ng is installed" \
  "stress-ng --version >/dev/null 2>&1"

# --- CPU stress ---
run_test "STRESS-02" "CPU stress — all cores (${T}s)" \
  "stress-ng --temp-path ${TP} --cpu 0 --cpu-method matrixprod --timeout ${T} --metrics-brief >/dev/null 2>&1 && systemctl is-active telegraf >/dev/null 2>&1 && systemctl is-active fluent-bit >/dev/null 2>&1"

# --- Memory stress ---
run_test "STRESS-03" "Memory stress — 80% RAM (${T}s)" \
  "stress-ng --temp-path ${TP} --vm 2 --vm-bytes 80% --vm-method all --timeout ${T} --metrics-brief >/dev/null 2>&1 && ! journalctl -b 0 --no-pager -q 2>/dev/null | grep -qi 'oom.*telegraf\|oom.*fluent'"

# --- Disk I/O stress ---
run_test "STRESS-04" "Disk I/O stress — sustained writes (${T}s)" \
  "stress-ng --temp-path /mnt/data --hdd 2 --hdd-bytes 64M --timeout ${T} --metrics-brief >/dev/null 2>&1 && test -w /mnt/data"

# --- Combined stress ---
run_test "STRESS-05" "Combined CPU+memory+I/O stress (${T}s)" \
  "stress-ng --temp-path /mnt/data --cpu 2 --vm 1 --vm-bytes 60% --hdd 1 --hdd-bytes 64M --timeout ${T} --metrics-brief >/dev/null 2>&1 && systemctl is-active telegraf >/dev/null 2>&1 && systemctl is-active fluent-bit >/dev/null 2>&1"

# --- Thermal check ---
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
  run_test "STRESS-06" "Thermal stays below 85C under CPU load" \
    "stress-ng --temp-path ${TP} --cpu 0 --timeout ${T} >/dev/null 2>&1 & PID=\$!; MAX=0; for i in 1 2 3 4 5; do sleep \$((T/5)); TEMP=\$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0); [ \"\$TEMP\" -gt \"\$MAX\" ] && MAX=\$TEMP; done; wait \$PID 2>/dev/null; [ \"\$MAX\" -lt 85000 ]"
else
  skip_test "STRESS-06" "Thermal check under load" "no thermal_zone0 sysfs"
fi

# --- OOM pressure + recovery ---
run_test "STRESS-07" "Services survive OOM pressure" \
  "stress-ng --temp-path ${TP} --vm 4 --vm-bytes 95% --timeout 15 >/dev/null 2>&1; sleep 5; systemctl is-active telegraf >/dev/null 2>&1 && systemctl is-active fluent-bit >/dev/null 2>&1"

# --- Fork bomb resilience ---
run_test "STRESS-08" "Fork bomb resilience (${T}s)" \
  "stress-ng --temp-path ${TP} --fork 4 --timeout ${T} --metrics-brief >/dev/null 2>&1; systemctl is-active telegraf >/dev/null 2>&1"

# --- Network under load ---
run_test "STRESS-09" "Telemetry flows under CPU load" \
  "stress-ng --temp-path ${TP} --cpu 0 --timeout ${T} >/dev/null 2>&1 & PID=\$!; sleep \$((T > 10 ? 10 : T)); OK=\$(! journalctl -u telegraf --since '30 sec ago' --no-pager -q 2>/dev/null | grep -qi 'timeout\|connection refused' && echo yes || echo no); wait \$PID 2>/dev/null; [ \"\$OK\" = 'yes' ]"

# --- 24h soak (always manual) ---
skip_test "STRESS-10" "24h soak test" "run manually: STRESS_TIMEOUT=86400 stress-ng --cpu 1 --vm 1 --vm-bytes 30%"

suite_end
