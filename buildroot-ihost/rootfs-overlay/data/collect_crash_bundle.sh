#!/usr/bin/env sh
set -eu

# Crash bundle collector (portable: works with sh/ash/busybox and bash)
# Live console output + saves everything into files + tar.gz bundle.

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

OUT_PARENT="${OUT_PARENT:-/mnt/data}"
LOG_LINES="${LOG_LINES:-5000}"
TIMEOUT_SEC="${TIMEOUT_SEC:-20}"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${OUT_PARENT%/}/crash-bundle-${TS}"
OUT_TAR="${OUT_PARENT%/}/crash-bundle-${TS}.tar.gz"

# Fallback if /mnt/data is not writable
if ! mkdir -p "$OUT_DIR" 2>/dev/null; then
  OUT_PARENT="/tmp"
  OUT_DIR="${OUT_PARENT%/}/crash-bundle-${TS}"
  OUT_TAR="${OUT_PARENT%/}/crash-bundle-${TS}.tar.gz"
  mkdir -p "$OUT_DIR"
fi

LOG_FILE="$OUT_DIR/_collector.log"

log() {
  # log to console + collector log
  printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

have() { command -v "$1" >/dev/null 2>&1; }

section() {
  log ""
  log "================================================================"
  log "$*"
  log "================================================================"
}

# Stream command output live to console and file, capture real exit code (no PIPESTATUS)
run_cmd() {
  name="$1"; shift
  file="$OUT_DIR/${name}.txt"
  cmd_display="$*"
  fifo="$OUT_DIR/.fifo_${name}"

  log "[RUN ] $name: $cmd_display"

  {
    echo "### CMD: $cmd_display"
    echo "### UTC: $(date -u '+%Y-%m-%d %H:%M:%S')"
    echo
  } | tee "$file"

  rm -f "$fifo" 2>/dev/null || true
  mkfifo "$fifo"

  # tee reads from fifo and prints to console + appends to file
  tee -a "$file" <"$fifo" &
  teepid=$!

  # run command, route stdout+stderr into fifo
  rc=0
  "$@" >"$fifo" 2>&1 || rc=$?

  # close fifo and wait for tee
  wait "$teepid" 2>/dev/null || true
  rm -f "$fifo" 2>/dev/null || true

  echo "" | tee -a "$file" >/dev/null
  echo "### EXIT: $rc" | tee -a "$file"

  if [ "$rc" -eq 0 ]; then
    log "[ OK ] $name -> $file"
  else
    log "[FAIL] $name (exit $rc) -> $file"
  fi
  return 0
}

# Same but for shell pipelines (portable)
run_sh() {
  name="$1"; shift
  sh_cmd="$*"
  file="$OUT_DIR/${name}.txt"
  fifo="$OUT_DIR/.fifo_${name}"

  log "[RUN ] $name: $sh_cmd"

  {
    echo "### SH: $sh_cmd"
    echo "### UTC: $(date -u '+%Y-%m-%d %H:%M:%S')"
    echo
  } | tee "$file"

  rm -f "$fifo" 2>/dev/null || true
  mkfifo "$fifo"

  tee -a "$file" <"$fifo" &
  teepid=$!

  rc=0
  # use sh -c for portability (avoid bash -lc)
  sh -c "$sh_cmd" >"$fifo" 2>&1 || rc=$?

  wait "$teepid" 2>/dev/null || true
  rm -f "$fifo" 2>/dev/null || true

  echo "" | tee -a "$file" >/dev/null
  echo "### EXIT: $rc" | tee -a "$file"

  if [ "$rc" -eq 0 ]; then
    log "[ OK ] $name -> $file"
  else
    log "[FAIL] $name (exit $rc) -> $file"
  fi
  return 0
}

copy_any() {
  src="$1"
  rel_dst="$2"
  dst="$OUT_DIR/$rel_dst"

  if [ -e "$src" ]; then
    log "[COPY] $src -> $dst"
    mkdir -p "$(dirname "$dst")" 2>/dev/null || true
    cp -a "$src" "$dst" 2>/dev/null || true
  else
    log "[SKIP] missing: $src"
  fi
}

section "Crash bundle collector"
log "Output directory: $OUT_DIR"
log "Timestamp (UTC):  $TS"
log "LOG_LINES:        $LOG_LINES"
log "TIMEOUT_SEC:      $TIMEOUT_SEC"

run_cmd "00_id" id
run_cmd "00_path" sh -c 'echo "$PATH"'

section "System identity / platform"
run_cmd "00_hostnamectl" hostnamectl
run_cmd "00_uname" uname -a
copy_any /etc/os-release "00_os-release"
copy_any /proc/cmdline "00_proc_cmdline"
copy_any /proc/uptime "00_proc_uptime"

section "CPU / SoC / Device Tree"
run_cmd "01_lscpu" lscpu
copy_any /proc/cpuinfo "01_proc_cpuinfo"
run_sh "01_dt_model" "cat /proc/device-tree/model 2>/dev/null; echo"
run_sh "01_dt_compatible" "tr -d '\0' < /proc/device-tree/compatible 2>/dev/null; echo"
run_sh "01_fdt_hash" "sha256sum /sys/firmware/fdt 2>/dev/null || true"

section "Storage / filesystem state"
run_cmd "02_lsblk" lsblk -a
run_cmd "02_df" df -hT
run_cmd "02_mount" mount

section "Kernel ring buffer (dmesg) - current boot"
run_cmd "10_dmesg" dmesg
run_cmd "10_dmesg_T" dmesg -T
run_sh "11_dmesg_crash_markers" \
  "dmesg 2>/dev/null | grep -i -E 'panic|oops|BUG:|watchdog|hung task|soft lockup|hard lockup|Out of memory|OOM|killed process|segfault|I/O error|mmc|ext4 error|btrfs error|reset|thermal|overheat' || true"

section "systemd journal (current + previous boot)"
if have journalctl; then
  run_cmd "20_journal_list_boots" journalctl --list-boots
  run_cmd "21_journal_k_current" journalctl -k -b 0 --no-pager -o short-precise
  run_cmd "22_journal_system_current" journalctl -b 0 --no-pager -o short-precise
  run_cmd "23_journal_k_prev1" journalctl -k -b -1 --no-pager -o short-precise
  run_cmd "24_journal_system_prev1" journalctl -b -1 --no-pager -o short-precise

  run_sh "25_journal_crash_markers_current" \
    "journalctl -b 0 --no-pager -o short-precise | grep -i -E 'panic|oops|BUG:|watchdog|hung task|soft lockup|hard lockup|Out of memory|OOM|killed process|segfault|I/O error|mmc|ext4 error|btrfs error|reset|thermal|overheat' || true"

  run_sh "26_journal_crash_markers_prev1" \
    "journalctl -b -1 --no-pager -o short-precise 2>/dev/null | grep -i -E 'panic|oops|BUG:|watchdog|hung task|soft lockup|hard lockup|Out of memory|OOM|killed process|segfault|I/O error|mmc|ext4 error|btrfs error|reset|thermal|overheat' || true"
else
  log "[SKIP] journalctl not found; skipping journal collection."
fi

section "pstore (persistent crash logs)"
if [ -d /sys/fs/pstore ] && [ "$(ls -A /sys/fs/pstore 2>/dev/null | wc -l | tr -d ' ')" != "0" ]; then
  log "[COPY] /sys/fs/pstore/* -> $OUT_DIR/30_pstore/"
  mkdir -p "$OUT_DIR/30_pstore" 2>/dev/null || true
  cp -a /sys/fs/pstore/* "$OUT_DIR/30_pstore/" 2>/dev/null || true
else
  log "[SKIP] No /sys/fs/pstore entries found."
fi

section "Home Assistant logs (ha CLI) - forced completion"
if have ha; then
  if have timeout; then
    run_sh "70_ha_core_logs_tail" \
      "timeout ${TIMEOUT_SEC}s ha core logs --no-color 2>/dev/null | tail -n ${LOG_LINES} || true"
    run_sh "71_ha_supervisor_logs_tail" \
      "timeout ${TIMEOUT_SEC}s ha supervisor logs --no-color 2>/dev/null | tail -n ${LOG_LINES} || true"
    run_sh "72_ha_host_logs_tail" \
      "timeout ${TIMEOUT_SEC}s ha host logs --no-color 2>/dev/null | tail -n ${LOG_LINES} || true"
    run_sh "73_ha_os_logs_tail" \
      "timeout ${TIMEOUT_SEC}s ha os logs --no-color 2>/dev/null | tail -n ${LOG_LINES} || true"
  else
    log "[WARN] 'timeout' not found; HA log commands may block on some systems."
    run_sh "70_ha_core_logs_tail" "ha core logs --no-color 2>/dev/null | tail -n ${LOG_LINES} || true"
    run_sh "71_ha_supervisor_logs_tail" "ha supervisor logs --no-color 2>/dev/null | tail -n ${LOG_LINES} || true"
    run_sh "72_ha_host_logs_tail" "ha host logs --no-color 2>/dev/null | tail -n ${LOG_LINES} || true"
    run_sh "73_ha_os_logs_tail" "ha os logs --no-color 2>/dev/null | tail -n ${LOG_LINES} || true"
  fi

  run_cmd "74_ha_info" ha info
  run_cmd "75_ha_core_info" ha core info
  run_cmd "76_ha_supervisor_info" ha supervisor info
else
  log "[SKIP] ha CLI not found."
fi

section "Docker/container logs (if available)"
if have docker; then
  run_cmd "90_docker_ps" docker ps -a
  run_sh "91_docker_logs_homeassistant_tail" "docker logs --tail ${LOG_LINES} homeassistant 2>&1 || true"
  run_sh "92_docker_logs_supervisor_tail" "docker logs --tail ${LOG_LINES} hassio_supervisor 2>&1 || true"
else
  log "[SKIP] docker not found."
fi

section "Home Assistant / Supervisor files on disk (best-effort copies)"
copy_any /mnt/data/supervisor "80_mnt_data_supervisor"
copy_any /mnt/data/homeassistant "81_mnt_data_homeassistant"
copy_any /mnt/data/logs "82_mnt_data_logs"
copy_any /var/log "83_var_log"
copy_any /run/log "84_run_log"

section "Create tarball"
# Prefer busybox tar compatibility: create in parent directory
( cd "$OUT_PARENT" && tar -czf "$OUT_TAR" "$(basename "$OUT_DIR")" ) 2>/dev/null || \
  tar -czf "$OUT_TAR" -C "$(dirname "$OUT_DIR")" "$(basename "$OUT_DIR")" 2>/dev/null || true

if [ -f "$OUT_TAR" ]; then
  log "[ OK ] Tarball created: $OUT_TAR"
else
  log "[FAIL] Tarball creation failed"
fi

section "Done"
echo "$OUT_TAR"
