#!/usr/bin/env bash
# =============================================================================
# run_device_tests.sh - Execute GA test suites on a remote device
# =============================================================================
# Copies test scripts to the device via SSH, executes them, returns results.
# Compatible with ga-flasher-py infrastructure (runner01-10 local, runner20 remote).
#
# Usage:
#   # Via SSH (direct IP)
#   ./tests/run_device_tests.sh --ssh root@192.168.1.100
#   ./tests/run_device_tests.sh --ssh root@192.168.1.100 --port 22222
#
#   # Via SSH (ga-flasher runner, auto-detects IP from VLAN)
#   ./tests/run_device_tests.sh --runner 1
#   ./tests/run_device_tests.sh --runner 20 --device-ip 192.168.31.123
#
#   # Via serial (tmux session, e.g. runner20)
#   ./tests/run_device_tests.sh --serial 20
#
#   # Run specific suites only
#   ./tests/run_device_tests.sh --ssh root@192.168.1.100 --suites "network ping"
#
# Environment:
#   SSH_KEY         - Path to SSH private key (optional, uses agent by default)
#   SSH_PORT        - SSH port (default: 22222 for HAOS dropbear)
#   DEVICE_IP       - Override device IP for runner mode
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TESTS_DIR="$SCRIPT_DIR/ga_tests"
REMOTE_DIR="/tmp/ga_tests"

# Defaults
MODE=""           # ssh, runner, serial
SSH_TARGET=""     # user@host
SSH_PORT="${SSH_PORT:-22222}"
SERIAL_PORT=""
RUNNER_NUM=""
DEVICE_IP="${DEVICE_IP:-}"
SUITES=""
SSH_KEY="${SSH_KEY:-}"

# GA-flasher paths
FLASHER_DIR="${FLASHER_DIR:-/home/user/git/ga-flasher-py}"
SERIAL_TMUX="$FLASHER_DIR/work/serial-tmux.sh"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Connection modes (pick one):"
    echo "  --ssh user@host      Connect via SSH directly"
    echo "  --runner N            Use ga-flasher runner N (1-13=local VLAN, 20=remote)"
    echo "  --serial N            Use serial tmux session N (via serial-tmux.sh)"
    echo ""
    echo "Options:"
    echo "  --port PORT           SSH port (default: 22222)"
    echo "  --device-ip IP        Override device IP (for runner mode)"
    echo "  --suites 'a b c'     Run only specified suites"
    echo "  --key PATH            SSH private key path"
    echo "  -h, --help            Show this help"
    echo ""
    echo "Available suites:"
    echo "  crash_detection telemetry environment network ping boot_timing disk_guard watchdog config_verify stress"
    echo "  crash_panic (host-side: triggers kernel panic, waits for reboot, verifies detection)"
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh)      MODE="ssh"; SSH_TARGET="$2"; shift 2 ;;
        --runner)   MODE="runner"; RUNNER_NUM="$2"; shift 2 ;;
        --serial)   MODE="serial"; SERIAL_PORT="$2"; shift 2 ;;
        --port)     SSH_PORT="$2"; shift 2 ;;
        --device-ip) DEVICE_IP="$2"; shift 2 ;;
        --suites)   SUITES="$2"; shift 2 ;;
        --key)      SSH_KEY="$2"; shift 2 ;;
        -h|--help)  usage ;;
        *)          echo "Unknown option: $1"; usage ;;
    esac
done

[[ -z "$MODE" ]] && { echo "ERROR: Specify --ssh, --runner, or --serial"; usage; }

# SSH options (same as ga-flasher ssh-helper.sh)
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR -o ServerAliveInterval=30 -o Port=$SSH_PORT"
[[ -n "$SSH_KEY" ]] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"

# --- Connection setup ---

setup_ssh() {
    echo "Mode: SSH direct ($SSH_TARGET:$SSH_PORT)"
}

setup_runner() {
    local num="$RUNNER_NUM"
    if [[ -z "$DEVICE_IP" ]]; then
        local vlan=$((100 + num))
        DEVICE_IP="192.168.${vlan}.100"
    fi
    SSH_TARGET="root@${DEVICE_IP}"
    echo "Mode: Runner $num (SSH to $SSH_TARGET:$SSH_PORT)"
}

setup_serial() {
    echo "Mode: Serial (port $SERIAL_PORT via tmux)"
    if [[ ! -x "$SERIAL_TMUX" ]]; then
        echo "ERROR: serial-tmux.sh not found at $SERIAL_TMUX"
        echo "Set FLASHER_DIR to your ga-flasher-py checkout"
        exit 1
    fi
}

# --- Execute via SSH ---

run_ssh() {
    echo ""
    echo "Copying test scripts to device..."
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$SSH_TARGET" "rm -rf $REMOTE_DIR" 2>/dev/null || true
    ssh $SSH_OPTS "$SSH_TARGET" "mkdir -p $REMOTE_DIR"

    # Copy test files using tar (scp -r may not work with dropbear)
    (cd "$TESTS_DIR" && tar cf - --exclude='*.md' --exclude='__pycache__' .) | \
        ssh $SSH_OPTS "$SSH_TARGET" "tar xf - -C $REMOTE_DIR"

    echo "Running tests on device..."
    echo ""

    # Execute
    local suite_args=""
    [[ -n "$SUITES" ]] && suite_args="$SUITES"

    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$SSH_TARGET" "sh $REMOTE_DIR/run_all.sh $suite_args" || true

    # Cleanup
    ssh $SSH_OPTS "$SSH_TARGET" "rm -rf $REMOTE_DIR" 2>/dev/null || true

    # Run host-side destructive tests (opt-in only — must be explicitly requested)
    if echo "$SUITES" | grep -qw "crash_panic"; then
        run_crash_panic_test
    fi
}

# --- Host-side: CRASH-04 kernel panic test ---
# This test must run from the host because the device crashes mid-test.

run_crash_panic_test() {
    echo ""
    echo "=== Crash Panic (host-side) ==="

    # Save crash_history.log line count before panic
    local before_count
    # shellcheck disable=SC2086
    before_count=$(ssh $SSH_OPTS "$SSH_TARGET" "wc -l < /mnt/data/crash_history.log 2>/dev/null || echo 0") || before_count=0

    echo "  Triggering kernel panic via sysrq..."
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$SSH_TARGET" "echo c > /proc/sysrq-trigger" 2>/dev/null &
    local ssh_pid=$!
    sleep 2
    kill $ssh_pid 2>/dev/null || true
    wait $ssh_pid 2>/dev/null || true

    # Wait for device to come back
    echo "  Waiting for reboot..."
    local attempts=0
    local max_attempts=60
    while [ $attempts -lt $max_attempts ]; do
        sleep 3
        # shellcheck disable=SC2086
        if ssh $SSH_OPTS "$SSH_TARGET" "echo OK" 2>/dev/null; then
            break
        fi
        attempts=$((attempts + 1))
    done

    if [ $attempts -ge $max_attempts ]; then
        printf "\033[0;31m  FAIL\033[0m  CRASH-04a: Device did not come back after panic (waited %ds)\n" $((max_attempts * 3))
        echo ""
        echo "--- Crash Panic: 0 passed, 1 failed, 0 skipped (1 total) ---"
        echo '{"suite":"Crash Panic","pass":0,"fail":1,"skip":0}'
        return
    fi

    local pass=0 fail=0

    # CRASH-04a: Journal shows unclean shutdown
    # shellcheck disable=SC2086
    local journal_out
    journal_out=$(ssh $SSH_OPTS "$SSH_TARGET" "journalctl -u ga-boot-check -b 0 --no-pager -q 2>/dev/null" 2>/dev/null) || journal_out=""
    if echo "$journal_out" | grep -q "UNCLEAN SHUTDOWN DETECTED"; then
        printf "\033[0;32m  PASS\033[0m  CRASH-04a: Kernel panic detected as unclean shutdown\n"
        pass=$((pass + 1))
    else
        printf "\033[0;31m  FAIL\033[0m  CRASH-04a: Kernel panic not detected in boot-check journal\n"
        fail=$((fail + 1))
    fi

    # CRASH-04b: crash_history.log has new entry
    local after_count
    # shellcheck disable=SC2086
    after_count=$(ssh $SSH_OPTS "$SSH_TARGET" "wc -l < /mnt/data/crash_history.log 2>/dev/null || echo 0") || after_count=0
    if [ "$after_count" -gt "$before_count" ]; then
        printf "\033[0;32m  PASS\033[0m  CRASH-04b: crash_history.log has new entry (%s -> %s lines)\n" "$before_count" "$after_count"
        pass=$((pass + 1))
    else
        printf "\033[0;31m  FAIL\033[0m  CRASH-04b: crash_history.log unchanged after panic (%s lines)\n" "$after_count"
        fail=$((fail + 1))
    fi

    # CRASH-04c: Previous boot logs accessible
    # shellcheck disable=SC2086
    if ssh $SSH_OPTS "$SSH_TARGET" "journalctl -b -1 2>/dev/null | head -1 | grep -q ." 2>/dev/null; then
        printf "\033[0;32m  PASS\033[0m  CRASH-04c: Previous boot logs accessible after panic\n"
        pass=$((pass + 1))
    else
        printf "\033[0;31m  FAIL\033[0m  CRASH-04c: Previous boot logs not available after panic\n"
        fail=$((fail + 1))
    fi

    # Show crash detection output
    # shellcheck disable=SC2086
    local crash_entry
    crash_entry=$(ssh $SSH_OPTS "$SSH_TARGET" "tail -1 /mnt/data/crash_history.log 2>/dev/null" 2>/dev/null) || crash_entry=""
    [ -n "$crash_entry" ] && echo "        -> $crash_entry"

    local total=$((pass + fail))
    echo ""
    echo "--- Crash Panic: ${pass} passed, ${fail} failed, 0 skipped (${total} total) ---"
    printf '{"suite":"Crash Panic","pass":%d,"fail":%d,"skip":0}\n' "$pass" "$fail"
}

# --- Execute via serial ---

run_serial() {
    local port="$SERIAL_PORT"

    # Ensure serial session is healthy
    "$SERIAL_TMUX" ensure "$port"
    sleep 1

    echo ""
    echo "Sending test commands via serial (port $port)..."
    echo "NOTE: Serial mode runs the quick test (no file transfer)"
    echo ""

    # In serial mode, we can't easily copy files. Instead, download from git or
    # use the inline quick test. For now, use the ga_quick_test.sh approach.
    # If the device has network, we could wget the scripts.

    # Check if device has network
    "$SERIAL_TMUX" send "$port" "ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && echo NET_OK || echo NET_FAIL"
    sleep 3
    local output
    output=$("$SERIAL_TMUX" capture "$port" 10)

    if echo "$output" | grep -q "NET_OK"; then
        echo "Device has network - attempting script transfer via wget..."
        # Try to get scripts from the local machine via python HTTP server
        echo "Starting temporary HTTP server for file transfer..."

        # Start HTTP server in background
        local http_port=8199
        (cd "$TESTS_DIR" && python3 -m http.server $http_port --bind 0.0.0.0 >/dev/null 2>&1) &
        local http_pid=$!
        sleep 1

        # Get host IP visible to device
        local host_ip
        host_ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[^ ]+' | head -1 || echo "")

        if [[ -n "$host_ip" ]]; then
            "$SERIAL_TMUX" send "$port" "mkdir -p $REMOTE_DIR && cd $REMOTE_DIR && wget -q http://${host_ip}:${http_port}/run_all.sh -O run_all.sh && echo DL_OK || echo DL_FAIL"
            sleep 5
            output=$("$SERIAL_TMUX" capture "$port" 5)

            if echo "$output" | grep -q "DL_OK"; then
                echo "Downloaded test runner. Running tests..."
                # Download all test files
                for suite in crash_detection telemetry environment network ping boot_timing disk_guard watchdog config_verify stress; do
                    "$SERIAL_TMUX" send "$port" "mkdir -p $REMOTE_DIR/$suite $REMOTE_DIR/lib"
                    sleep 0.5
                    "$SERIAL_TMUX" send "$port" "wget -q http://${host_ip}:${http_port}/$suite/test.sh -O $REMOTE_DIR/$suite/test.sh 2>/dev/null"
                    sleep 0.5
                done
                "$SERIAL_TMUX" send "$port" "wget -q http://${host_ip}:${http_port}/lib/test_helpers.sh -O $REMOTE_DIR/lib/test_helpers.sh"
                sleep 2

                local suite_args=""
                [[ -n "$SUITES" ]] && suite_args="$SUITES"
                "$SERIAL_TMUX" send "$port" "sh $REMOTE_DIR/run_all.sh $suite_args"

                # Wait for completion and capture output
                echo "Waiting for tests to complete..."
                sleep 30
                "$SERIAL_TMUX" capture "$port" 200
            else
                echo "Download failed. Falling back to inline quick test."
                run_serial_inline "$port"
            fi
        else
            echo "Cannot determine host IP. Falling back to inline quick test."
            run_serial_inline "$port"
        fi

        kill $http_pid 2>/dev/null || true
    else
        echo "No network on device. Running inline quick test."
        run_serial_inline "$port"
    fi
}

# Fallback: send inline test commands via serial
run_serial_inline() {
    local port="$1"
    local quick_test="$SCRIPT_DIR/ga_quick_test.sh"

    if [[ -f "$quick_test" ]]; then
        echo "Sending quick test via serial (line by line)..."
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            "$SERIAL_TMUX" send "$port" "$line"
            sleep 1
        done < "$quick_test"
        sleep 5
        "$SERIAL_TMUX" capture "$port" 100
    else
        echo "ERROR: ga_quick_test.sh not found"
        exit 1
    fi
}

# --- Main ---

case "$MODE" in
    ssh)     setup_ssh; run_ssh ;;
    runner)  setup_runner; run_ssh ;;
    serial)  setup_serial; run_serial ;;
esac
