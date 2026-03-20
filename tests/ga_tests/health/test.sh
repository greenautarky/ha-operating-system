#!/bin/sh
# Health check test suite - runs ON the device
# Verifies Docker containers, HA Core API, addons, DNS, time sync,
# and disk space are healthy after provisioning.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Health"

# --- Docker health ---

run_test "HLTH-01" "Docker daemon running" \
  "docker info >/dev/null 2>&1"

# All containers should be running (not restarting/exited)
if command -v docker >/dev/null 2>&1; then
  BAD=$(docker ps -a --filter "status=restarting" --filter "status=exited" --format '{{.Names}}' 2>/dev/null | grep -v '^$' | wc -l)
  run_test_show "HLTH-02" "No crashed/restarting containers (got ${BAD})" \
    "[ \"$BAD\" -eq 0 ]"

  run_test "HLTH-03" "homeassistant container running" \
    "docker inspect -f '{{.State.Status}}' homeassistant 2>/dev/null | grep -q running"

  run_test "HLTH-04" "hassio_supervisor container running" \
    "docker inspect -f '{{.State.Status}}' hassio_supervisor 2>/dev/null | grep -q running"
else
  skip_test "HLTH-02" "No crashed/restarting containers" "docker not found"
  skip_test "HLTH-03" "homeassistant container running" "docker not found"
  skip_test "HLTH-04" "hassio_supervisor container running" "docker not found"
fi

# --- HA Core API ---

run_test "HLTH-05" "HA Core API responds (GET /api/)" \
  "wget -q -O /dev/null --timeout=10 http://127.0.0.1:8123/api/ 2>/dev/null || curl -sf --connect-timeout 10 http://127.0.0.1:8123/api/ >/dev/null 2>&1"

run_test "HLTH-06" "Supervisor API responds" \
  "docker exec hassio_supervisor curl -sf --connect-timeout 5 http://127.0.0.1/supervisor/info >/dev/null 2>&1 || ha supervisor info >/dev/null 2>&1"

# --- Addon health ---

# Check pre-baked addons are running (if installed)
for addon in addon_core_mosquitto addon_a0d7b954_ga_tailscale; do
  name=$(echo "$addon" | sed 's/addon_core_//;s/addon_[a-f0-9]*_//')
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "$addon"; then
    run_test "HLTH-07-${name}" "Addon ${name} running" \
      "docker inspect -f '{{.State.Status}}' $addon 2>/dev/null | grep -q running"
  else
    skip_test "HLTH-07-${name}" "Addon ${name} running" "not installed"
  fi
done

# --- DNS resolution ---

run_test "HLTH-08a" "DNS resolves github.com" \
  "nslookup github.com >/dev/null 2>&1 || getent hosts github.com >/dev/null 2>&1"

run_test "HLTH-08b" "DNS resolves ghcr.io" \
  "nslookup ghcr.io >/dev/null 2>&1 || getent hosts ghcr.io >/dev/null 2>&1"

# --- Time sync ---

# Check NTP sync status via timedatectl or systemd-timesyncd
if command -v timedatectl >/dev/null 2>&1; then
  run_test "HLTH-09" "System clock synchronized (NTP)" \
    "timedatectl show 2>/dev/null | grep -q 'NTPSynchronized=yes' || timedatectl 2>/dev/null | grep -qi 'synchronized: yes\|clock synchronized'"
else
  # Fallback: check if systemd-timesyncd is running
  warn_test "HLTH-09" "Time sync service active" \
    "systemctl is-active systemd-timesyncd >/dev/null 2>&1"
fi

# --- Disk space ---

DATA_USE_PCT=$(df /mnt/data 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
DATA_FREE_MB=$(df -m /mnt/data 2>/dev/null | awk 'NR==2 {print $4}')
run_test_show "HLTH-10" "/mnt/data usage < 80% (${DATA_USE_PCT:-?}%, ${DATA_FREE_MB:-?} MB free)" \
  "[ \"${DATA_USE_PCT:-100}\" -lt 80 ]"

# --- Journal persistence ---

# Check that journal has entries (proves persistence is working)
JOURNAL_ENTRIES=$(journalctl -b 0 --no-pager -q 2>/dev/null | wc -l)
run_test_show "HLTH-11" "Journal has entries for current boot (${JOURNAL_ENTRIES})" \
  "[ \"$JOURNAL_ENTRIES\" -gt 10 ]"

suite_end
