#!/bin/bash
# run_ota_test.sh — Fully automated OTA update + rollback test
#
# Runs from the HOST (laptop/CI), orchestrates 3 phases on the device:
#   Phase 1: Upload bundle, install, reboot
#   Phase 2: Verify slot switch + data persistence, rollback, reboot
#   Phase 3: Verify rollback, restore updated slot, reboot
#
# Usage:
#   ./tests/run_ota_test.sh --device-ip <IP> --raucb <path>
#
# Options:
#   --device-ip IP       Device NetBird/LAN IP
#   --raucb PATH         Path to .raucb file on host
#   --ssh-key PATH       SSH key (default: HomeassistantGreen0.pem)
#   --ssh-port PORT      SSH port (default: 22222)
#   --timeout SECS       Max wait for reboot (default: 120)
#
set -euo pipefail

DEVICE_IP=""
RAUCB_PATH=""
SSH_KEY="${SSH_KEY:-$HOME/Nextcloud2/GreenAutarky/security_store/HomeassistantGreen0.pem}"
SSH_PORT="${SSH_PORT:-22222}"
REBOOT_TIMEOUT="${REBOOT_TIMEOUT:-120}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --device-ip) DEVICE_IP="$2"; shift 2 ;;
    --raucb)     RAUCB_PATH="$2"; shift 2 ;;
    --ssh-key)   SSH_KEY="$2"; shift 2 ;;
    --ssh-port)  SSH_PORT="$2"; shift 2 ;;
    --timeout)   REBOOT_TIMEOUT="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

[[ -z "$DEVICE_IP" ]] && { echo "ERROR: --device-ip required"; exit 1; }
[[ -z "$RAUCB_PATH" ]] && { echo "ERROR: --raucb required"; exit 1; }
[[ ! -f "$RAUCB_PATH" ]] && { echo "ERROR: RAUCB not found: $RAUCB_PATH"; exit 1; }
[[ ! -f "$SSH_KEY" ]] && { echo "ERROR: SSH key not found: $SSH_KEY"; exit 1; }

SSH_CMD="ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSH_PORT -i $SSH_KEY root@$DEVICE_IP"
SCP_CMD="scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P $SSH_PORT -i $SSH_KEY"

TESTS_DIR="$(cd "$(dirname "$0")/ga_tests" && pwd)"

wait_for_device() {
  local max_wait="$1"
  local start=$(date +%s)
  echo -n "  Waiting for device"
  while true; do
    if $SSH_CMD 'echo ok' 2>/dev/null | grep -q ok; then
      echo " UP ($(( $(date +%s) - start ))s)"
      return 0
    fi
    if [ $(( $(date +%s) - start )) -gt "$max_wait" ]; then
      echo " TIMEOUT after ${max_wait}s"
      return 1
    fi
    echo -n "."
    sleep 10
  done
}

upload_tests() {
  echo "  Uploading test suite..."
  $SCP_CMD -r "$TESTS_DIR" root@$DEVICE_IP:/tmp/ 2>/dev/null
}

run_on_device() {
  $SSH_CMD "$@" 2>&1
}

echo "=============================================="
echo "  OTA Update Test — Fully Automated"
echo "=============================================="
echo "  Device:  $DEVICE_IP"
echo "  Bundle:  $(basename "$RAUCB_PATH")"
echo "  SSH key:  $SSH_KEY"
echo ""

# --- Pre-flight ---
echo "=== Pre-flight ==="
run_on_device 'grep PRETTY_NAME /etc/os-release; rauc status 2>/dev/null | grep "Booted from:"'
echo ""

# --- Upload bundle ---
echo "=== Uploading RAUC bundle ($(du -h "$RAUCB_PATH" | cut -f1)) ==="
$SCP_CMD "$RAUCB_PATH" root@$DEVICE_IP:/mnt/data/ota_test_bundle.raucb
echo "  Upload complete."
echo ""

# --- Phase 1: Install + reboot ---
echo "=== Phase 1: Install + Reboot ==="
upload_tests
# Run test suite — it will install, write markers, and reboot
run_on_device "RAUCB_PATH=/mnt/data/ota_test_bundle.raucb sh /tmp/ga_tests/ota_update/test.sh" || true
echo ""

# --- Wait for reboot ---
echo "=== Waiting for reboot (Phase 1 → Phase 2) ==="
sleep 15
wait_for_device "$REBOOT_TIMEOUT" || { echo "FATAL: Device did not come back"; exit 1; }
echo ""

# --- Phase 2: Post-OTA verify + rollback + reboot ---
echo "=== Phase 2: Post-OTA Verification + Rollback ==="
upload_tests
run_on_device "sh /tmp/ga_tests/ota_update/test.sh" || true
echo ""

# --- Wait for reboot ---
echo "=== Waiting for reboot (Phase 2 → Phase 3) ==="
sleep 15
wait_for_device "$REBOOT_TIMEOUT" || { echo "FATAL: Device did not come back after rollback"; exit 1; }
echo ""

# --- Phase 3: Post-rollback verify + restore ---
echo "=== Phase 3: Rollback Verification + Restore ==="
upload_tests
run_on_device "sh /tmp/ga_tests/ota_update/test.sh" || true
echo ""

# --- Wait for final reboot (restore to updated slot) ---
echo "=== Waiting for final reboot (restored to updated slot) ==="
sleep 15
wait_for_device "$REBOOT_TIMEOUT" || { echo "FATAL: Device did not come back after restore"; exit 1; }
echo ""

# --- Final state ---
echo "=== Final State ==="
run_on_device 'grep PRETTY_NAME /etc/os-release; rauc status 2>/dev/null | grep -E "Booted|boot status"'
echo ""

# --- Cleanup ---
echo "=== Cleanup ==="
run_on_device 'rm -f /mnt/data/ota_test_bundle.raucb /mnt/data/.ota_test_phase /mnt/data/.ota_test_data; echo "Cleaned up"'
echo ""

echo "=============================================="
echo "  OTA Test Complete"
echo "=============================================="
