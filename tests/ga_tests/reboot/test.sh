#!/usr/bin/env bash
# Reboot & Power-Loss test suite — runs FROM THE HOST, not on the device
#
# Usage (called by run_device_tests.sh or standalone):
#   REBOOT_TEST=1 ./test.sh                    # Single clean reboot
#   POWER_LOSS_TEST=1 ./test.sh                # Single power loss cycle
#   STRESS_REBOOT=5 ./test.sh                  # 5x clean reboot stress test
#   REBOOT_TEST=1 POWER_LOSS_TEST=1 ./test.sh  # Both
#
# Environment:
#   DEVICE_IP        — Device IP (required)
#   SSH_PORT         — SSH port (default: 22222)
#   USB_POWER_CMD    — Command to power cycle USB (for power loss test)
#   REBOOT_TIMEOUT   — Max seconds to wait for device (default: 180)
#   HA_API_TIMEOUT   — Max seconds to wait for HA API (default: 300)
#   CSV_FILE         — Path to CSV output file (default: reboot-results.csv in reports/)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Defaults
SSH_PORT="${SSH_PORT:-22222}"
REBOOT_TIMEOUT="${REBOOT_TIMEOUT:-180}"
HA_API_TIMEOUT="${HA_API_TIMEOUT:-300}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

# CSV output
CSV_FILE="${CSV_FILE:-${SCRIPT_DIR}/../../../ga_output/images/reports/reboot-results.csv}"
mkdir -p "$(dirname "$CSV_FILE")" 2>/dev/null || true

csv_init() {
    if [[ ! -f "$CSV_FILE" ]]; then
        echo "iteration,type,timestamp,shutdown_s,ping_return_s,ssh_ready_s,api_ready_s,total_s,result" > "$CSV_FILE"
    fi
}

csv_row() {
    echo "$1,$2,$(date -Iseconds),$3,$4,$5,$6,$7,$8" >> "$CSV_FILE"
}

# Counters
_pass=0 _fail=0 _skip=0

_p() { echo "  PASS  $1"; _pass=$((_pass + 1)); }
_f() { echo "  FAIL  $1"; _fail=$((_fail + 1)); }
_s() { echo "  SKIP  $1"; _skip=$((_skip + 1)); }
_info() { echo "  INFO  $1"; }

ssh_cmd() {
    ssh $SSH_OPTS -p "$SSH_PORT" "root@${DEVICE_IP}" "$@" 2>/dev/null
}

# Wait for ping to return (device booted enough for network)
wait_for_ping() {
    local timeout="$1"
    local start=$SECONDS
    while (( SECONDS - start < timeout )); do
        if ping -c 1 -W 1 "$DEVICE_IP" &>/dev/null; then
            echo $(( SECONDS - start ))
            return 0
        fi
        sleep 1
    done
    return 1
}

# Wait for SSH to respond
wait_for_ssh() {
    local timeout="$1"
    local start=$SECONDS
    while (( SECONDS - start < timeout )); do
        if ssh_cmd "echo ok" &>/dev/null; then
            echo $(( SECONDS - start ))
            return 0
        fi
        sleep 2
    done
    return 1
}

# Wait for HA Core API to respond (HTTP 200 or 401)
wait_for_ha_api() {
    local timeout="$1"
    local start=$SECONDS
    while (( SECONDS - start < timeout )); do
        local code
        code=$(ssh_cmd "curl -sf -o /dev/null -w '%{http_code}' --connect-timeout 3 http://127.0.0.1:8123/api/ 2>/dev/null" || echo "000")
        if [[ "$code" == "200" || "$code" == "401" ]]; then
            echo $(( SECONDS - start ))
            return 0
        fi
        sleep 3
    done
    return 1
}

# Capture device baseline
capture_baseline() {
    _info "Capturing baseline..."
    if [[ "$SSH_AVAILABLE" == "true" ]]; then
        BASELINE_BOOT_ID=$(ssh_cmd "cat /proc/sys/kernel/random/boot_id" || echo "unknown")
        BASELINE_UPTIME=$(ssh_cmd "cat /proc/uptime | cut -d' ' -f1" || echo "0")
        _info "  boot_id: ${BASELINE_BOOT_ID}"
        _info "  uptime:  ${BASELINE_UPTIME}s"
    else
        BASELINE_BOOT_ID="unknown"
        BASELINE_UPTIME="0"
        _info "  (ping-only mode — no baseline capture)"
    fi
}

# Verify device recovered after reboot
verify_recovery() {
    local test_prefix="$1"
    local expect_crash="$2"  # "yes" for power loss, "no" for clean reboot

    if [[ "$SSH_AVAILABLE" != "true" ]]; then
        _s "${test_prefix}-01..08: SSH not available (ping-only mode)"
        return 0
    fi

    # New boot_id
    local new_boot_id
    new_boot_id=$(ssh_cmd "cat /proc/sys/kernel/random/boot_id" || echo "unknown")
    if [[ "$new_boot_id" != "$BASELINE_BOOT_ID" && "$new_boot_id" != "unknown" ]]; then
        _p "${test_prefix}-01: New boot_id after reboot"
    else
        _f "${test_prefix}-01: boot_id unchanged (device did not reboot?)"
    fi

    # Uptime < 5 min
    local new_uptime
    new_uptime=$(ssh_cmd "cat /proc/uptime | cut -d' ' -f1 | cut -d. -f1" || echo "9999")
    if [[ "$new_uptime" -lt 300 ]]; then
        _p "${test_prefix}-02: Uptime ${new_uptime}s (< 300s, freshly booted)"
    else
        _f "${test_prefix}-02: Uptime ${new_uptime}s (expected < 300s)"
    fi

    # Docker running
    if ssh_cmd "docker ps --format '{{.Names}}' | grep -q homeassistant" &>/dev/null; then
        _p "${test_prefix}-03: Docker + homeassistant container running"
    else
        _f "${test_prefix}-03: homeassistant container not running"
    fi

    # Supervisor running
    if ssh_cmd "docker ps --format '{{.Names}}' | grep -q hassio_supervisor" &>/dev/null; then
        _p "${test_prefix}-04: Supervisor container running"
    else
        _f "${test_prefix}-04: Supervisor container not running"
    fi

    # No crashed/restarting containers
    local crashed
    crashed=$(ssh_cmd "docker ps -a --filter 'status=restarting' --format '{{.Names}}' | wc -l" || echo "?")
    if [[ "$crashed" == "0" ]]; then
        _p "${test_prefix}-05: No crashed/restarting containers"
    else
        _f "${test_prefix}-05: ${crashed} containers restarting"
    fi

    # Crash marker
    if [[ "$expect_crash" == "yes" ]]; then
        # Power loss — crash should be detected
        if ssh_cmd "grep -q 'CRASH DETECTED' /mnt/data/crash_history.log 2>/dev/null"; then
            _p "${test_prefix}-06: Crash detected in crash_history.log (expected for power loss)"
        else
            _f "${test_prefix}-06: No crash detected (expected crash marker for power loss)"
        fi
    else
        # Clean reboot — no crash
        local marker
        marker=$(ssh_cmd "test -f /mnt/data/.ga_unclean_shutdown && echo 'stale' || echo 'clean'" || echo "unknown")
        if [[ "$marker" == "clean" ]]; then
            _p "${test_prefix}-06: Clean shutdown detected (no stale crash marker)"
        else
            _f "${test_prefix}-06: Stale crash marker found after clean reboot"
        fi
    fi

    # Filesystem OK (data partition writable)
    if ssh_cmd "touch /mnt/data/.reboot_test_probe && rm /mnt/data/.reboot_test_probe" &>/dev/null; then
        _p "${test_prefix}-07: /mnt/data filesystem writable"
    else
        _f "${test_prefix}-07: /mnt/data not writable"
    fi

    # Ethernet guard applied correctly
    local eth_disabled
    eth_disabled=$(ssh_cmd "grep -q '^GA_ETHERNET_DISABLED=true' /mnt/data/ga-env.conf 2>/dev/null && echo yes || echo no")
    local eth_state
    eth_state=$(ssh_cmd "nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep '^eth0:' | cut -d: -f2" || echo "unknown")
    if [[ "$eth_disabled" == "yes" ]]; then
        if [[ "$eth_state" != "connected" ]]; then
            _p "${test_prefix}-08: Ethernet guard applied (disabled + eth0 not connected)"
        else
            _f "${test_prefix}-08: Ethernet guard NOT applied (flag=true but eth0 connected)"
        fi
    else
        _p "${test_prefix}-08: Ethernet enabled (no guard needed)"
    fi
}

# === Clean Reboot Test ===
run_reboot_test() {
    local iteration="${1:-1}"
    local prefix="RBT"
    [[ "$iteration" -gt 1 ]] && prefix="RBT-${iteration}"

    echo ""
    echo "  === Clean Reboot Test (iteration ${iteration}) ==="
    capture_baseline

    # Trigger reboot
    _info "Triggering reboot..."
    local reboot_start=$SECONDS
    if [[ "$SSH_AVAILABLE" == "true" ]]; then
        ssh_cmd "reboot" &>/dev/null || true
    elif [[ -c "${SERIAL_DEV:-/dev/ttyACM0}" ]]; then
        _info "  Using serial to trigger reboot..."
        SERIAL_DEV="${SERIAL_DEV:-/dev/ttyACM0}" SERIAL_PASS="${SERIAL_PASS:-}" python3 -c "
import serial, time, os
dev = os.environ.get('SERIAL_DEV', '/dev/ttyACM0')
pw = os.environ.get('SERIAL_PASS', '')
s = serial.Serial(dev, 115200, timeout=2)
s.write(b'\r\n'); time.sleep(0.5); s.read(s.in_waiting)
s.write(b'root\r\n'); time.sleep(1); s.read(s.in_waiting)
s.write(pw.encode() + b'\r\n'); time.sleep(2); s.read(s.in_waiting)
s.write(b'reboot\r\n'); time.sleep(1)
s.close()
" 2>/dev/null || { _f "${prefix}-REBOOT: Could not trigger reboot via serial"; return 1; }
    else
        _f "${prefix}-REBOOT: No way to trigger reboot (no SSH, no serial)"
        return 1
    fi
    sleep 3

    # Wait for ping to go down (confirms device is rebooting)
    _info "Waiting for device to go down..."
    local down_wait=0
    while ping -c 1 -W 1 "$DEVICE_IP" &>/dev/null && (( down_wait < 30 )); do
        sleep 1
        down_wait=$((down_wait + 1))
    done
    _info "  Device went down after ${down_wait}s"

    # Wait for ping to come back
    _info "Waiting for ping (timeout: ${REBOOT_TIMEOUT}s)..."
    local ping_time
    if ping_time=$(wait_for_ping "$REBOOT_TIMEOUT"); then
        _p "${prefix}-PING: Ping returned after ${ping_time}s"
    else
        _f "${prefix}-PING: Device did not respond to ping within ${REBOOT_TIMEOUT}s"
        return 1
    fi

    # Wait for SSH (if available)
    local ssh_time="N/A"
    local api_time="N/A"
    if [[ "$SSH_AVAILABLE" == "true" ]]; then
        _info "Waiting for SSH (timeout: ${REBOOT_TIMEOUT}s)..."
        if ssh_time=$(wait_for_ssh "$REBOOT_TIMEOUT"); then
            _p "${prefix}-SSH: SSH ready after ${ssh_time}s (from ping return)"
        else
            _f "${prefix}-SSH: SSH did not respond within ${REBOOT_TIMEOUT}s"
            ssh_time="timeout"
        fi

        # Wait for HA API
        _info "Waiting for HA Core API (timeout: ${HA_API_TIMEOUT}s)..."
        if api_time=$(wait_for_ha_api "$HA_API_TIMEOUT"); then
            _p "${prefix}-API: HA Core API ready after ${api_time}s (from SSH ready)"
        else
            _f "${prefix}-API: HA Core API did not respond within ${HA_API_TIMEOUT}s"
            api_time="timeout"
        fi
    else
        _s "${prefix}-SSH: SSH not available (ping-only mode)"
        _s "${prefix}-API: HA API check skipped (ping-only mode)"
    fi

    local total_time=$(( SECONDS - reboot_start ))
    _info "  Total reboot cycle: ${total_time}s"
    echo "        -> reboot_total=${total_time}s ping=${ping_time:-?}s ssh=${ssh_time:-?}s api=${api_time:-?}s"

    # Verify recovery
    verify_recovery "$prefix" "no"

    # Threshold check
    local result="PASS"
    if [[ "${total_time}" -lt 180 ]]; then
        _p "${prefix}-TIME: Total reboot time ${total_time}s (< 180s threshold)"
    else
        _f "${prefix}-TIME: Total reboot time ${total_time}s (>= 180s threshold)"
        result="FAIL"
    fi

    # CSV
    csv_row "$iteration" "reboot" "$down_wait" "${ping_time:-0}" "${ssh_time:-0}" "${api_time:-0}" "$total_time" "$result"
}

# === Power Loss Test ===
run_power_loss_test() {
    local prefix="PWR"

    echo ""
    echo "  === Power Loss Test ==="

    if [[ -z "${USB_POWER_CMD:-}" ]]; then
        _s "${prefix}: USB_POWER_CMD not set (set to power control command)"
        _info "Example: USB_POWER_CMD='/path/to/a16_port_power.sh <port>'"
        return 0
    fi

    capture_baseline

    # Power OFF
    _info "Cutting power (USB)..."
    local power_start=$SECONDS
    eval "${USB_POWER_CMD} off" || { _f "${prefix}-POWER: Power off command failed"; return 1; }
    _info "  Power off. Waiting 5s..."
    sleep 5

    # Power ON
    _info "Restoring power..."
    eval "${USB_POWER_CMD} on" || { _f "${prefix}-POWER: Power on command failed"; return 1; }

    # Wait for ping
    _info "Waiting for ping (timeout: ${REBOOT_TIMEOUT}s)..."
    local ping_time
    if ping_time=$(wait_for_ping "$REBOOT_TIMEOUT"); then
        _p "${prefix}-PING: Ping returned after ${ping_time}s"
    else
        _f "${prefix}-PING: Device did not respond to ping within ${REBOOT_TIMEOUT}s"
        return 1
    fi

    # Wait for SSH
    _info "Waiting for SSH..."
    local ssh_time
    if ssh_time=$(wait_for_ssh "$REBOOT_TIMEOUT"); then
        _p "${prefix}-SSH: SSH ready after ${ssh_time}s"
    else
        _f "${prefix}-SSH: SSH did not respond within ${REBOOT_TIMEOUT}s"
        return 1
    fi

    # Wait for HA API
    _info "Waiting for HA Core API..."
    local api_time
    if api_time=$(wait_for_ha_api "$HA_API_TIMEOUT"); then
        _p "${prefix}-API: HA Core API ready after ${api_time}s"
    else
        _f "${prefix}-API: HA Core API did not respond within ${HA_API_TIMEOUT}s"
    fi

    local total_time=$(( SECONDS - power_start ))
    _info "  Total power cycle: ${total_time}s"
    echo "        -> power_total=${total_time}s ping=${ping_time:-?}s ssh=${ssh_time:-?}s api=${api_time:-?}s"

    # Verify recovery (expect crash)
    verify_recovery "$prefix" "yes"

    # Threshold check
    local result="PASS"
    if [[ "${total_time}" -lt 240 ]]; then
        _p "${prefix}-TIME: Total power cycle time ${total_time}s (< 240s threshold)"
    else
        _f "${prefix}-TIME: Total power cycle time ${total_time}s (>= 240s threshold)"
        result="FAIL"
    fi

    # CSV
    csv_row "1" "power_loss" "0" "${ping_time:-0}" "${ssh_time:-0}" "${api_time:-0}" "$total_time" "$result"
}

# === Main ===

if [[ -z "${DEVICE_IP:-}" ]]; then
    echo "ERROR: DEVICE_IP is required"
    echo "Usage: DEVICE_IP=<ip> REBOOT_TEST=1 $0"
    exit 1
fi

echo "=== Reboot & Power-Loss Tests ==="
echo "  Device:  ${DEVICE_IP}:${SSH_PORT}"
echo "  Timeouts: ping/ssh=${REBOOT_TIMEOUT}s api=${HA_API_TIMEOUT}s"
echo ""

# Wait for device to be reachable (handles case where device is still booting)
echo "  Waiting for device to come online..."
_online_wait=0
while ! ping -c 1 -W 1 "$DEVICE_IP" &>/dev/null && (( _online_wait < 120 )); do
    sleep 2
    _online_wait=$((_online_wait + 2))
done
if ! ping -c 1 -W 2 "$DEVICE_IP" &>/dev/null; then
    echo "ERROR: Device not reachable at ${DEVICE_IP} after 120s"
    exit 1
fi
[[ "$_online_wait" -gt 0 ]] && echo "  Device came online after ${_online_wait}s"

# Check connectivity — SSH preferred, ping-only fallback
SSH_AVAILABLE=false
if ssh_cmd "echo ok" &>/dev/null; then
    SSH_AVAILABLE=true
    echo "  Device reachable via SSH. Full verification enabled."
else
    echo "  Device reachable via ping only (SSH unavailable). Ping-only mode."
fi
echo "  CSV output: ${CSV_FILE}"
csv_init
echo "  Starting tests..."

# Clean reboot test
if [[ "${REBOOT_TEST:-0}" == "1" || -n "${STRESS_REBOOT:-}" ]]; then
    ITERATIONS="${STRESS_REBOOT:-1}"
    for i in $(seq 1 "$ITERATIONS"); do
        run_reboot_test "$i"
        if [[ "$i" -lt "$ITERATIONS" ]]; then
            _info "Waiting 30s before next reboot cycle..."
            sleep 30
        fi
    done
fi

# Power loss test
if [[ "${POWER_LOSS_TEST:-0}" == "1" ]]; then
    run_power_loss_test
fi

# No test requested
if [[ "${REBOOT_TEST:-0}" != "1" && -z "${STRESS_REBOOT:-}" && "${POWER_LOSS_TEST:-0}" != "1" ]]; then
    _s "RBT: Clean reboot test (set REBOOT_TEST=1)"
    _s "PWR: Power loss test (set POWER_LOSS_TEST=1 + USB_POWER_CMD)"
    _s "STRESS: Stress reboot test (set STRESS_REBOOT=N)"
fi

echo ""
echo "--- Reboot Tests: ${_pass} passed, ${_fail} failed, ${_skip} skipped ---"
echo "{\"suite\":\"Reboot\",\"pass\":${_pass},\"fail\":${_fail},\"skip\":${_skip}}"

exit "$_fail"
