#!/bin/sh
# Idle performance test suite - runs ON the device
# Measures baseline resource usage when the system is idle (no user activity).
# Samples over 60 seconds to avoid false positives from momentary spikes.
# Run after boot stabilisation (~5 min uptime) for reliable results.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Idle Performance"

SAMPLE_SECS="${IDLE_SAMPLE_SECS:-60}"

# --- IDLE-01: Total RAM detected (expect ~4GB) ---
MEM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
run_test_show "IDLE-01" "Total RAM detected >= 3800 MB (got ${MEM_TOTAL_MB} MB)" \
  "[ \"$MEM_TOTAL_MB\" -ge 3800 ]"

# --- IDLE-02: Available RAM > 15% of total ---
MEM_AVAIL_KB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
MEM_AVAIL_MB=$((MEM_AVAIL_KB / 1024))
MEM_AVAIL_PCT=$((MEM_AVAIL_KB * 100 / MEM_TOTAL_KB))
run_test_show "IDLE-02" "Available RAM > 15% of total (${MEM_AVAIL_MB} MB = ${MEM_AVAIL_PCT}%)" \
  "[ \"$MEM_AVAIL_PCT\" -gt 15 ]"

# --- IDLE-03: CPU idle % over sampling period ---
# Uses /proc/stat (works on BusyBox, no extra tools needed)
idle_pct() {
  read_cpu() { awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat; }
  set -- $(read_cpu); TOTAL1=$1; IDLE1=$2
  sleep "$SAMPLE_SECS"
  set -- $(read_cpu); TOTAL2=$1; IDLE2=$2
  DTOTAL=$((TOTAL2 - TOTAL1))
  DIDLE=$((IDLE2 - IDLE1))
  if [ "$DTOTAL" -gt 0 ]; then
    echo $((DIDLE * 100 / DTOTAL))
  else
    echo 0
  fi
}
echo "        -> Sampling CPU for ${SAMPLE_SECS}s..."
CPU_IDLE=$(idle_pct)
run_test_show "IDLE-03" "CPU idle > 80% over ${SAMPLE_SECS}s (got ${CPU_IDLE}%)" \
  "[ \"$CPU_IDLE\" -gt 80 ]"

# --- IDLE-04: Load average (5-min) ---
LOAD5=$(awk '{print $2}' /proc/loadavg)
# Shell can't do float comparison — multiply by 10 and compare to 20
LOAD5_X10=$(echo "$LOAD5" | awk '{printf "%d", $1 * 10}')
run_test_show "IDLE-04" "5-min load average < 2.0 (got ${LOAD5})" \
  "[ \"$LOAD5_X10\" -lt 20 ]"

# --- IDLE-05: Disk I/O wait ---
# iowait is field 5 in /proc/stat cpu line
iowait_pct() {
  read_iow() { awk '/^cpu / {print $2+$3+$4+$5+$6+$7+$8, $6}' /proc/stat; }
  set -- $(read_iow); TOTAL1=$1; IOW1=$2
  sleep 10
  set -- $(read_iow); TOTAL2=$1; IOW2=$2
  DTOTAL=$((TOTAL2 - TOTAL1))
  DIOW=$((IOW2 - IOW1))
  if [ "$DTOTAL" -gt 0 ]; then
    echo $((DIOW * 100 / DTOTAL))
  else
    echo 0
  fi
}
IOWAIT=$(iowait_pct)
run_test_show "IDLE-05" "I/O wait < 5% (got ${IOWAIT}%)" \
  "[ \"$IOWAIT\" -lt 5 ]"

# --- IDLE-06: Swap usage ---
SWAP_TOTAL_KB=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
SWAP_USED_KB=$(awk '/^SwapTotal:/ {t=$2} /^SwapFree:/ {print t-$2}' /proc/meminfo)
SWAP_USED_MB=$((SWAP_USED_KB / 1024))
if [ "$SWAP_TOTAL_KB" -eq 0 ]; then
  run_test_show "IDLE-06" "No swap configured (OK for 4GB system)" "true"
else
  run_test_show "IDLE-06" "Swap usage < 50 MB (got ${SWAP_USED_MB} MB)" \
    "[ \"$SWAP_USED_MB\" -lt 50 ]"
fi

# --- IDLE-07: No OOM kills since boot ---
OOM_COUNT=$(dmesg 2>/dev/null | grep -c "Out of memory" || true)
OOM_COUNT=${OOM_COUNT:-0}
run_test_show "IDLE-07" "No OOM kills since boot (got ${OOM_COUNT})" \
  "[ \"$OOM_COUNT\" -eq 0 ]"

# --- IDLE-08: No systemd failed units ---
FAILED=$(systemctl --failed --no-legend --no-pager 2>/dev/null | grep -c '.' || true)
FAILED=${FAILED:-0}
# Show which units failed for diagnostics
FAILED_LIST=$(systemctl --failed --no-legend --no-pager 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
run_test_show "IDLE-08" "No systemd failed units (got ${FAILED}: ${FAILED_LIST:-none})" \
  "[ \"$FAILED\" -eq 0 ]"

# --- IDLE-09: Top CPU consumer < 10% ---
# Use top in batch mode — 2 iterations, take second (first is since boot)
TOP_PROC=$(top -bn2 -d5 2>/dev/null | awk '
  /^top -/ { iter++ }
  iter==2 && /^ *[0-9]/ && NR>3 {
    if ($9+0 > max) { max=$9+0; name=$12 }
  }
  END { printf "%d %s", max, name }
')
TOP_CPU=$(echo "$TOP_PROC" | awk '{print $1}')
TOP_NAME=$(echo "$TOP_PROC" | awk '{print $2}')
run_test_show "IDLE-09" "No process > 10% CPU (top: ${TOP_NAME} at ${TOP_CPU}%)" \
  "[ \"${TOP_CPU:-0}\" -lt 10 ]"

# --- IDLE-10: Docker container stats ---
if command -v docker >/dev/null 2>&1; then
  # docker stats --no-stream gives CPU% per container
  DOCKER_STATS=$(docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}' 2>/dev/null || true)
  if [ -n "$DOCKER_STATS" ]; then
    # Check homeassistant container < 15%
    HA_CPU=$(echo "$DOCKER_STATS" | awk '/homeassistant/ {gsub(/%/,"",$2); printf "%d", $2}')
    run_test_show "IDLE-10a" "HA Core container CPU < 15% (got ${HA_CPU:-0}%)" \
      "[ \"${HA_CPU:-0}\" -lt 15 ]"

    # Check supervisor container < 5%
    SUP_CPU=$(echo "$DOCKER_STATS" | awk '/hassio_supervisor/ {gsub(/%/,"",$2); printf "%d", $2}')
    run_test_show "IDLE-10b" "Supervisor container CPU < 5% (got ${SUP_CPU:-0}%)" \
      "[ \"${SUP_CPU:-0}\" -lt 5 ]"

    # Show all container stats
    run_test_show "IDLE-10c" "Docker container summary" \
      "docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null"
  else
    skip_test "IDLE-10a" "HA Core container CPU" "docker stats unavailable"
    skip_test "IDLE-10b" "Supervisor container CPU" "docker stats unavailable"
    skip_test "IDLE-10c" "Docker container summary" "docker stats unavailable"
  fi
else
  skip_test "IDLE-10a" "HA Core container CPU" "docker not found"
  skip_test "IDLE-10b" "Supervisor container CPU" "docker not found"
  skip_test "IDLE-10c" "Docker container summary" "docker not found"
fi

# --- IDLE-11: Temperature (auto-skip if no sensor) ---
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
  TEMP_MC=$(cat /sys/class/thermal/thermal_zone0/temp)
  TEMP_C=$((TEMP_MC / 1000))
  run_test_show "IDLE-11" "CPU temperature < 60C idle (got ${TEMP_C}C)" \
    "[ \"$TEMP_C\" -lt 60 ]"
else
  skip_test "IDLE-11" "CPU temperature < 60C idle" "no thermal sensor found"
fi

suite_end
