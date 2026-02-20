#!/usr/bin/env bash
# power_cycle/test.sh - Power-cycle restart stress test (HOST-SIDE)
# =================================================================
# Unlike other ga_tests suites, this script runs on the HOST machine,
# not on the device. It controls power via an external hook and monitors
# boot progress via serial-tmux.sh.
#
# Usage:
#   ./tests/ga_tests/power_cycle/test.sh --port 20 [OPTIONS]
#
# Required:
#   --port N              Serial port number (for serial-tmux.sh)
#
# Options:
#   --cycles N            Number of power cycles (default: 100)
#   --off-time N          Seconds to keep power off (default: 5)
#   --boot-timeout N      Seconds to wait for boot (default: 120)
#   --power-cmd-off CMD   Shell command to power off device
#   --power-cmd-on CMD    Shell command to power on device
#   --power-api URL       host-power-service.py REST API URL
#   --power-port N        Port number for power API (default: same as --port)
#   --output-dir DIR      Directory for results (default: ./results)
#   --prompt-pattern PAT  Regex for boot-complete (default: '#\s*$|login:|KiBu')
#   --post-boot-check     Run health checks after final cycle
#   --max-hangs N         Abort after N consecutive hangs (default: 3)
#   -h, --help            Show this help
#
# Environment variables (override defaults, CLI overrides env):
#   PWR_CYCLES, PWR_OFF_TIME, PWR_BOOT_TIMEOUT, PWR_POWER_CMD_OFF,
#   PWR_POWER_CMD_ON, PWR_POWER_API, PWR_SERIAL_PORT, PWR_OUTPUT_DIR,
#   FLASHER_DIR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ────────────────────────────────────────────────────────
SERIAL_PORT="${PWR_SERIAL_PORT:-}"
CYCLES="${PWR_CYCLES:-100}"
OFF_TIME="${PWR_OFF_TIME:-5}"
BOOT_TIMEOUT="${PWR_BOOT_TIMEOUT:-120}"
POWER_CMD_OFF="${PWR_POWER_CMD_OFF:-}"
POWER_CMD_ON="${PWR_POWER_CMD_ON:-}"
POWER_API="${PWR_POWER_API:-}"
POWER_PORT="${PWR_POWER_PORT:-}"
OUTPUT_DIR="${PWR_OUTPUT_DIR:-${SCRIPT_DIR}/results}"
PROMPT_PATTERN='(#\s*$|login:|KiBu)'
POST_BOOT_CHECK=false
MAX_CONSECUTIVE_HANGS=3
FLASHER_DIR="${FLASHER_DIR:-/home/user/git/ga-flasher-py}"
SERIAL_TMUX="$FLASHER_DIR/work/serial-tmux.sh"

# Power control variables (set by resolve_power_method)
POWER_METHOD=""

# ── CLI argument parsing ────────────────────────────────────────────
usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)           SERIAL_PORT="$2"; shift 2 ;;
        --cycles)         CYCLES="$2"; shift 2 ;;
        --off-time)       OFF_TIME="$2"; shift 2 ;;
        --boot-timeout)   BOOT_TIMEOUT="$2"; shift 2 ;;
        --power-cmd-off)  POWER_CMD_OFF="$2"; shift 2 ;;
        --power-cmd-on)   POWER_CMD_ON="$2"; shift 2 ;;
        --power-api)      POWER_API="$2"; shift 2 ;;
        --power-port)     POWER_PORT="$2"; shift 2 ;;
        --output-dir)     OUTPUT_DIR="$2"; shift 2 ;;
        --prompt-pattern) PROMPT_PATTERN="$2"; shift 2 ;;
        --post-boot-check) POST_BOOT_CHECK=true; shift ;;
        --max-hangs)      MAX_CONSECUTIVE_HANGS="$2"; shift 2 ;;
        -h|--help)        usage ;;
        *)                echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Validation ──────────────────────────────────────────────────────
if [[ -z "$SERIAL_PORT" ]]; then
    echo "ERROR: --port is required" >&2
    exit 1
fi

if [[ ! -x "$SERIAL_TMUX" ]]; then
    echo "ERROR: serial-tmux.sh not found at $SERIAL_TMUX" >&2
    echo "  Set FLASHER_DIR to the ga-flasher-py directory" >&2
    exit 1
fi

# Default power-port to serial port
POWER_PORT="${POWER_PORT:-$SERIAL_PORT}"

# Source power control abstraction
source "$SCRIPT_DIR/power_ctl.sh"
resolve_power_method

# Verify serial session is alive
if ! "$SERIAL_TMUX" healthy "$SERIAL_PORT" >/dev/null 2>&1; then
    echo "ERROR: Serial session for port $SERIAL_PORT is not healthy" >&2
    echo "  Start it with: $SERIAL_TMUX start $SERIAL_PORT <device>" >&2
    exit 1
fi

# ── Output setup ────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV_FILE="$OUTPUT_DIR/power_cycle_${TIMESTAMP}.csv"
SUMMARY_FILE="$OUTPUT_DIR/power_cycle_${TIMESTAMP}_summary.txt"
LOG_FILE="$OUTPUT_DIR/power_cycle_${TIMESTAMP}.log"

echo "cycle,boot_time_s,result,timestamp,notes" > "$CSV_FILE"

# ── Logging ─────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ── Boot detection ──────────────────────────────────────────────────
# Two-phase approach:
#   Phase 1: Wait for U-Boot/kernel signature (proves device actually rebooted,
#            avoids false positive from stale prompt in serial buffer)
#   Phase 2: Wait for shell prompt (boot complete)

wait_for_boot() {
    local timeout="$1"
    local start
    start=$(date +%s)
    local saw_reboot=false

    # Ensure serial session is alive (picocom may need to reconnect after power-off)
    "$SERIAL_TMUX" ensure "$SERIAL_PORT" >/dev/null 2>&1 || true

    while true; do
        local now elapsed output
        now=$(date +%s)
        elapsed=$(( now - start ))

        if (( elapsed >= timeout )); then
            echo "TIMEOUT"
            return 1
        fi

        output=$("$SERIAL_TMUX" capture "$SERIAL_PORT" 30 2>/dev/null) || {
            sleep 1
            continue
        }

        # Phase 1: Look for evidence the device is actually rebooting
        if ! $saw_reboot; then
            if echo "$output" | grep -qiE 'U-Boot|Starting kernel|Booting Linux|DDR Version|DRAM:'; then
                saw_reboot=true
                log "    Reboot detected ($(( elapsed ))s)"
            fi
            sleep 1
            continue
        fi

        # Phase 2: Watch for shell prompt (boot complete)
        if echo "$output" | grep -qE "$PROMPT_PATTERN"; then
            echo "$elapsed"
            return 0
        fi

        # Detect kernel panic
        if echo "$output" | grep -qiE 'kernel panic|Oops|BUG:|Unable to mount root'; then
            echo "PANIC"
            return 2
        fi

        sleep 1
    done
}

# ── Post-boot health checks (PWR-04..PWR-07) ───────────────────────
serial_cmd() {
    # Send command via serial console and capture output
    local cmd="$1"
    local wait="${2:-3}"
    "$SERIAL_TMUX" send "$SERIAL_PORT" "$cmd" >/dev/null 2>&1
    sleep "$wait"
    "$SERIAL_TMUX" capture "$SERIAL_PORT" 15 2>/dev/null
}

run_post_checks() {
    log ""
    log "=== Post-Boot Health Checks ==="

    # Wait for services to settle
    sleep 10

    # PWR-04: Filesystem integrity
    local output
    output=$(serial_cmd "dmesg | grep -ciE 'error|fault|corrupt' || echo FS_ERRORS=0" 5)
    if echo "$output" | grep -q "FS_ERRORS=0"; then
        log "  PWR-04 Filesystem integrity:  PASS"
        echo "PWR-04,PASS,Filesystem integrity" >> "$SUMMARY_FILE"
    else
        log "  PWR-04 Filesystem integrity:  FAIL"
        echo "PWR-04,FAIL,Filesystem integrity" >> "$SUMMARY_FILE"
    fi

    # Also check /mnt/data is writable
    output=$(serial_cmd "touch /mnt/data/.pwr_test && rm /mnt/data/.pwr_test && echo WRITABLE" 3)
    if echo "$output" | grep -q "WRITABLE"; then
        log "  PWR-04b /mnt/data writable:   PASS"
    else
        log "  PWR-04b /mnt/data writable:   FAIL"
    fi

    # PWR-05: Crash detection
    output=$(serial_cmd "journalctl -u ga-boot-check -b 0 --no-pager -q 2>/dev/null | tail -1" 3)
    if echo "$output" | grep -qiE "UNCLEAN|Clean boot|Finished"; then
        log "  PWR-05 Crash detection log:   PASS"
        echo "PWR-05,PASS,Crash detection log" >> "$SUMMARY_FILE"
    else
        log "  PWR-05 Crash detection log:   FAIL"
        echo "PWR-05,FAIL,Crash detection log" >> "$SUMMARY_FILE"
    fi

    # PWR-06: Services running
    output=$(serial_cmd "systemctl is-active telegraf ga-disk-guard.timer 2>/dev/null" 3)
    if echo "$output" | grep -q "^active"; then
        log "  PWR-06 Services running:      PASS"
        echo "PWR-06,PASS,Services running" >> "$SUMMARY_FILE"
    else
        log "  PWR-06 Services running:      FAIL"
        echo "PWR-06,FAIL,Services running" >> "$SUMMARY_FILE"
    fi

    # PWR-07: Boot count
    output=$(serial_cmd "journalctl --list-boots 2>/dev/null | wc -l" 3)
    local boot_count
    boot_count=$(echo "$output" | grep -oE '[0-9]+' | tail -1)
    log "  PWR-07 Journal boot count:    ${boot_count:-?}"
    echo "PWR-07,INFO,Boot count: ${boot_count:-unknown}" >> "$SUMMARY_FILE"
}

# ── Summary generation ──────────────────────────────────────────────
generate_summary() {
    local total=$CYCLES
    local ok=$pass_count
    local hangs=$hang_count
    local errors=$error_count
    local panics=$panic_count
    local duration=$(( $(date +%s) - test_start_time ))
    local duration_fmt
    duration_fmt="$(( duration / 3600 ))h $(( (duration % 3600) / 60 ))m $(( duration % 60 ))s"

    # Calculate boot time stats with awk
    local stats="0 0 0 0 0 0 0"
    if (( ${#boot_times[@]} > 0 )); then
        stats=$(printf '%s\n' "${boot_times[@]}" | awk '
        {
            sum += $1; sumsq += $1*$1; a[NR] = $1; n++
        }
        END {
            if (n == 0) { print "0 0 0 0 0 0 0"; exit }
            mean = sum / n
            variance = (n > 1) ? (sumsq - sum*sum/n) / (n-1) : 0
            stddev = sqrt(variance)
            # Sort for median/percentiles
            for (i = 1; i <= n; i++)
                for (j = i+1; j <= n; j++)
                    if (a[i] > a[j]) { t=a[i]; a[i]=a[j]; a[j]=t }
            median = (n % 2) ? a[int(n/2)+1] : (a[n/2] + a[n/2+1]) / 2
            p95 = int(n * 0.95); if (p95 < 1) p95 = 1
            p99 = int(n * 0.99); if (p99 < 1) p99 = 1
            printf "%d %d %.1f %d %.1f %d %d\n", a[1], a[n], mean, median, stddev, a[p95], a[p99]
        }')
    fi

    read -r s_min s_max s_mean s_median s_stddev s_p95 s_p99 <<< "$stats"

    # Write summary
    {
        echo "=== Power-Cycle Stress Test Summary ==="
        echo "Date:        $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Duration:    $duration_fmt"
        echo "Device:      Serial port $SERIAL_PORT"
        echo ""
        echo "Configuration:"
        echo "  Cycles:       $CYCLES"
        echo "  Off-time:     ${OFF_TIME}s"
        echo "  Boot timeout: ${BOOT_TIMEOUT}s"
        echo "  Power method: $POWER_METHOD"
        echo ""
        echo "Results:"
        echo "  Total cycles: $total"
        echo "  Completed:    $(( ok + hangs + errors + panics ))"
        printf "  OK:           %d (%.1f%%)\n" "$ok" "$(awk "BEGIN{printf \"%.1f\", $ok/$total*100}")"
        printf "  HANG:         %d (%.1f%%)\n" "$hangs" "$(awk "BEGIN{printf \"%.1f\", $hangs/$total*100}")"
        printf "  PANIC:        %d (%.1f%%)\n" "$panics" "$(awk "BEGIN{printf \"%.1f\", $panics/$total*100}")"
        printf "  ERROR:        %d (%.1f%%)\n" "$errors" "$(awk "BEGIN{printf \"%.1f\", $errors/$total*100}")"
        echo ""
        if (( ${#boot_times[@]} > 0 )); then
            echo "Boot Time Statistics (${#boot_times[@]} successful boots):"
            echo "  Min:          ${s_min}s"
            echo "  Max:          ${s_max}s"
            echo "  Mean:         ${s_mean}s"
            echo "  Median:       ${s_median}s"
            echo "  Stddev:       ${s_stddev}s"
            echo "  P95:          ${s_p95}s"
            echo "  P99:          ${s_p99}s"
        else
            echo "Boot Time Statistics: No successful boots"
        fi
        echo ""
        echo "CSV log: $CSV_FILE"
    } | tee "$SUMMARY_FILE"
}

# ── Signal handling ─────────────────────────────────────────────────
cleanup() {
    log ""
    log "!!! Test interrupted at cycle ${cycle:-?}/$CYCLES !!!"
    generate_summary
    exit 130
}
trap cleanup INT TERM

# ── Main loop ───────────────────────────────────────────────────────
pass_count=0
hang_count=0
error_count=0
panic_count=0
boot_times=()
consecutive_hangs=0
test_start_time=$(date +%s)

log "=============================================="
log "  Power-Cycle Stress Test"
log "  Cycles: $CYCLES, Off-time: ${OFF_TIME}s, Timeout: ${BOOT_TIMEOUT}s"
log "  Serial port: $SERIAL_PORT"
log "  Output: $OUTPUT_DIR"
log "=============================================="
log ""

for (( cycle=1; cycle<=CYCLES; cycle++ )); do
    log "--- Cycle $cycle/$CYCLES ---"

    # 1. Power off
    log "  Power OFF"
    if ! power_off; then
        log "  ERROR: Power off command failed"
        echo "$cycle,,ERROR,$(date -Iseconds),power_off_failed" >> "$CSV_FILE"
        error_count=$((error_count + 1))
        continue
    fi

    # 2. Wait off-time
    log "  Waiting ${OFF_TIME}s (power off)"
    sleep "$OFF_TIME"

    # 3. Power on
    log "  Power ON"
    if ! power_on; then
        log "  ERROR: Power on command failed"
        echo "$cycle,,ERROR,$(date -Iseconds),power_on_failed" >> "$CSV_FILE"
        error_count=$((error_count + 1))
        continue
    fi

    # 4. Wait for boot (two-phase: reboot signature → shell prompt)
    log "  Waiting for boot (timeout: ${BOOT_TIMEOUT}s)..."
    result=$(wait_for_boot "$BOOT_TIMEOUT")
    rc=$?

    case $rc in
        0)
            log "  BOOT OK in ${result}s"
            echo "$cycle,$result,OK,$(date -Iseconds)," >> "$CSV_FILE"
            boot_times+=("$result")
            pass_count=$((pass_count + 1))
            consecutive_hangs=0
            ;;
        1)
            log "  HANG - boot timeout exceeded (${BOOT_TIMEOUT}s)"
            # Capture serial output for diagnosis
            log "  Serial output at timeout:"
            "$SERIAL_TMUX" capture "$SERIAL_PORT" 20 2>/dev/null | while IFS= read -r line; do
                log "    | $line"
            done
            echo "$cycle,,HANG,$(date -Iseconds),timeout_${BOOT_TIMEOUT}s" >> "$CSV_FILE"
            hang_count=$((hang_count + 1))
            consecutive_hangs=$((consecutive_hangs + 1))
            if (( consecutive_hangs >= MAX_CONSECUTIVE_HANGS )); then
                log ""
                log "ABORT: $MAX_CONSECUTIVE_HANGS consecutive hangs — device may be bricked"
                break
            fi
            ;;
        2)
            log "  PANIC - kernel panic detected"
            "$SERIAL_TMUX" capture "$SERIAL_PORT" 20 2>/dev/null | while IFS= read -r line; do
                log "    | $line"
            done
            echo "$cycle,,PANIC,$(date -Iseconds),kernel_panic" >> "$CSV_FILE"
            panic_count=$((panic_count + 1))
            consecutive_hangs=$((consecutive_hangs + 1))
            if (( consecutive_hangs >= MAX_CONSECUTIVE_HANGS )); then
                log ""
                log "ABORT: $MAX_CONSECUTIVE_HANGS consecutive panics/hangs"
                break
            fi
            ;;
    esac

    log ""
done

# ── Post-boot health checks ────────────────────────────────────────
if $POST_BOOT_CHECK && (( pass_count > 0 )); then
    run_post_checks
fi

# ── Summary ─────────────────────────────────────────────────────────
log ""
generate_summary
log ""
log "=== Test Complete ==="
log "Results: $pass_count OK, $hang_count HANG, $panic_count PANIC, $error_count ERROR (of $CYCLES cycles)"

# Exit with number of failures
exit $(( hang_count + error_count + panic_count ))
