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
# Exclude known expected failures:
#   audio-setup.service — masked at runtime by ga-overlay-init (no audio hardware)
#   ga-overlay-init.service — runs once at first boot, ConditionPathExists prevents re-run
FAILED_LIST=$(systemctl --failed --no-legend --no-pager 2>/dev/null \
  | grep -v 'audio-setup\|ga-overlay-init' \
  | awk '{print $2}' | tr '\n' ' ')
FAILED=$(echo "$FAILED_LIST" | wc -w)
FAILED=${FAILED:-0}
run_test_show "IDLE-08" "No unexpected failed units (got ${FAILED}: ${FAILED_LIST:-none})" \
  "[ \"$FAILED\" -eq 0 ]"

# --- IDLE-09: no process holds the CPU ---
#
# Three things this check got wrong, all measured on K31 (BOSv1.3.0-rc23,
# 2026-09-07), and each made it report something other than the device:
#
#  1. IT READ THE WRONG COLUMN. It took $9 as %CPU. On this device top prints
#     PID USER PR NI VIRT RES %CPU %MEM TIME+ S COMMAND — so $9 is TIME+, the
#     CUMULATIVE CPU MINUTES. It announced "netbird at 292%" for a process
#     using about 6%. A check that grows more likely to fail the longer a
#     device is up is measuring uptime, not load.
#  2. IT JUDGED ON ONE 5-SECOND SAMPLE taken while this suite was running.
#  3. Comparing only the WORST process per sample hides the real case: with
#     several processes above the limit, the worst differs between samples and
#     a genuinely stuck process passes. (Caught by re-measuring this very fix:
#     influxd held 10–96% across four samples and the max-comparison let it
#     through.)
#
# So: read %CPU by header position, take two real samples (top's first
# iteration is since-boot averages), and fail on the INTERSECTION — a pid over
# the limit in BOTH samples. Names come from /proc/<pid>/comm, because top
# truncates deep tree rows to "+".
IDLE09_TOP="/tmp/ga-idle09-top.txt"
top -bn3 -d5 > "$IDLE09_TOP" 2>/dev/null

# pids over $1 percent in sample $2, one "pid pct" per line
_idle09_over() {
  awk -v lim="$1" -v want="$2" '
    /^top -/ { iter++ }
    /%CPU/ && cpu_col == 0 { for (i = 1; i <= NF; i++) if ($i == "%CPU") cpu_col = i; next }
    iter == want && cpu_col > 0 && $1 ~ /^[0-9]+$/ && $cpu_col + 0 >= lim { print $1 " " $cpu_col }
  ' "$IDLE09_TOP"
}

# netbird's keepalive spikes are normal and always had a wider band.
IDLE09_LIMIT=10
IDLE09_NETBIRD_LIMIT=20

IDLE09_OFFENDERS=""
for _pid in $(_idle09_over "$IDLE09_LIMIT" 2 | cut -d' ' -f1); do
  _pct3=$(_idle09_over "$IDLE09_LIMIT" 3 | awk -v p="$_pid" '$1 == p { print $2; exit }')
  [ -n "$_pct3" ] || continue                     # not sustained — one sample only
  _pct2=$(_idle09_over "$IDLE09_LIMIT" 2 | awk -v p="$_pid" '$1 == p { print $2; exit }')
  _comm=$(cat "/proc/${_pid}/comm" 2>/dev/null || echo unknown)
  case "$_comm" in
    *netbird*)
      # only an offender above its own wider band
      awk -v a="$_pct2" -v b="$_pct3" -v l="$IDLE09_NETBIRD_LIMIT" \
          'BEGIN { exit !(a + 0 >= l && b + 0 >= l) }' || continue ;;
  esac
  IDLE09_OFFENDERS="$IDLE09_OFFENDERS ${_comm}(${_pid}) ${_pct2}%->${_pct3}%;"
done
rm -f "$IDLE09_TOP"
IDLE09_OFFENDERS=$(echo "$IDLE09_OFFENDERS" | sed 's/^ //')

run_test_show "IDLE-09" "No process sustained over ${IDLE09_LIMIT}% CPU across two samples (${IDLE09_OFFENDERS:-none})" \
  "[ -z \"$IDLE09_OFFENDERS\" ]"

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
