#!/bin/sh
# Tailscale addon test suite - runs ON the device
# Verifies ga_tailscale addon is running with correct hostname.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Tailscale"

# Find the ga_tailscale container name (may vary by addon ID prefix)
TS_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep 'ga_tailscale' | head -1)

# --- Container running ---
run_test "TS-01" "ga_tailscale addon container running" \
  "[ -n '$TS_CONTAINER' ]"

if [ -z "$TS_CONTAINER" ]; then
  skip_test "TS-02" "Tailscale connected" "container not running"
  skip_test "TS-03" "Hostname matches device label" "container not running"
  skip_test "TS-04" "Tailscale IP assigned" "container not running"
  skip_test "TS-05" "greenautarky addon image" "container not running"
else
  # --- Connection status ---
  run_test "TS-02" "Tailscale daemon is connected" \
    "docker exec $TS_CONTAINER /opt/tailscale status 2>/dev/null | head -1 | grep -qv 'stopped\|not running'"

  # --- Hostname matches device label ---
  TS_HOSTNAME=$(docker exec "$TS_CONTAINER" /opt/tailscale status --json 2>/dev/null | grep -o '"Self":{[^}]*}' | grep -o '"HostName":"[^"]*"' | cut -d'"' -f4)
  DEVICE_LABEL=$(cat /mnt/data/ga-device-label 2>/dev/null)

  if [ -n "$DEVICE_LABEL" ] && [ -n "$TS_HOSTNAME" ]; then
    run_test "TS-03" "Tailscale hostname matches device label" \
      "[ '$TS_HOSTNAME' = '$DEVICE_LABEL' ]"
  elif [ -z "$DEVICE_LABEL" ]; then
    skip_test "TS-03" "Hostname matches device label" "no ga-device-label file"
  else
    run_test "TS-03" "Tailscale hostname matches device label" \
      "false"
  fi

  run_test_show "TS-03b" "Tailscale hostname" \
    "echo 'tailscale=$TS_HOSTNAME device_label=$DEVICE_LABEL'"

  # --- IP assigned ---
  run_test "TS-04" "Tailscale has IP assigned" \
    "docker exec $TS_CONTAINER /opt/tailscale ip -4 2>/dev/null | grep -q '^100\.'"

  run_test_show "TS-04b" "Tailscale IP" \
    "docker exec $TS_CONTAINER /opt/tailscale ip -4 2>/dev/null"

  # --- Image registry ---
  TS_IMAGE=$(docker inspect "$TS_CONTAINER" --format '{{.Config.Image}}' 2>/dev/null)
  run_test "TS-05" "Uses greenautarky addon image (not upstream)" \
    "echo '$TS_IMAGE' | grep -q 'greenautarky'"

  run_test_show "TS-05b" "Addon image" \
    "echo '$TS_IMAGE'"
fi

suite_end
