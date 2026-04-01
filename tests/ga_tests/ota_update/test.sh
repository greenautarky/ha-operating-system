#!/bin/sh
# OTA / RAUC Update test suite - runs ON the device
#
# Tests RAUC slot status, data persistence, and rollback.
# OTA-09 (full end-to-end install) must be run separately with a .raucb file.
#
# All tests FAIL if requirements not met (no RAUC, no dual slots).
#
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "OTA Update"

# --- OTA-01: RAUC status shows healthy ---
run_test "OTA-01" "RAUC service available" \
  "command -v rauc >/dev/null 2>&1"

run_test "OTA-01b" "RAUC shows booted slot" \
  "rauc status 2>/dev/null | grep -q 'Booted from:'"

BOOTED_SLOT=$(rauc status 2>/dev/null | grep 'Booted from:' | grep -oE 'kernel\.[01]' || echo "unknown")
run_test_show "OTA-01c" "Booted slot" "echo $BOOTED_SLOT"

# Both slots present
run_test "OTA-01d" "Both A/B slots present" \
  "rauc status 2>/dev/null | grep -q 'bootname.*A' && rauc status 2>/dev/null | grep -q 'bootname.*B'"

# Booted slot marked as good
run_test "OTA-01e" "Booted slot status is good" \
  "rauc status 2>/dev/null | grep -A2 'booted' | grep -q 'good'"

# --- OTA-02: RAUC compatible matches device ---
COMPAT=$(rauc status 2>/dev/null | grep 'Compatible:' | awk '{print $2}')
run_test "OTA-02" "RAUC compatible is haos-ihost" \
  "[ '$COMPAT' = 'haos-ihost' ]"

# --- OTA-03: OS version from CPE ---
VERSION_ID=$(grep 'VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2)
run_test_show "OTA-03" "OS version from os-release" "echo $VERSION_ID"

CPE_VER=$(grep 'CPE_NAME=' /etc/os-release 2>/dev/null | sed 's/.*haos://;s/:.*//')
run_test "OTA-03b" "CPE version matches VERSION_ID" \
  "[ '$VERSION_ID' = '$CPE_VER' ]"

# --- OTA-04: Persistent data survives (check existing markers) ---
run_test "OTA-04" "Data partition mounted" \
  "mountpoint -q /mnt/data"

run_test "OTA-04b" "Supervisor data present after OTA" \
  "test -d /mnt/data/supervisor"

# --- OTA-05: RAUC keyring present ---
run_test "OTA-05" "RAUC keyring certificate exists" \
  "test -f /etc/rauc/keyring.pem"

run_test "OTA-05b" "RAUC system.conf exists" \
  "test -f /etc/rauc/system.conf"

# --- OTA-06: Slot B version (if available) ---
SLOT_B_VER=$(rauc status 2>/dev/null | grep -A5 'kernel.1' | grep 'bundle.version' | awk '{print $NF}' || true)
if [ -n "$SLOT_B_VER" ]; then
  run_test_show "OTA-06" "Slot B bundle version" "echo $SLOT_B_VER"
else
  skip_test "OTA-06" "Slot B bundle version (not installed yet)"
fi

# --- OTA-07: Journal boots survive OTA ---
BOOT_COUNT=$(journalctl --list-boots 2>/dev/null | wc -l)
run_test "OTA-07" "Journal has boot history" \
  "[ $BOOT_COUNT -gt 0 ]"
run_test_show "OTA-07b" "Boot count in journal" "echo $BOOT_COUNT"

# --- OTA-08: Services running after OTA ---
for svc in telegraf fluent-bit netbird; do
  run_test "OTA-08-$svc" "Service $svc active after boot" \
    "systemctl is-active $svc >/dev/null 2>&1"
done

# --- OTA-09: RAUC bundle install (only if RAUCB_PATH is set) ---
RAUCB="${RAUCB_PATH:-}"
if [ -n "$RAUCB" ] && [ -f "$RAUCB" ]; then
  # Pre-install: write marker
  echo "ota-test-marker" > /mnt/data/ota_test_marker

  run_test "OTA-09a" "RAUC bundle signature valid" \
    "rauc info '$RAUCB' 2>&1 | grep -q 'Verified'"

  BUNDLE_VER=$(rauc info "$RAUCB" 2>/dev/null | grep "Version:" | awk '{print $2}' | tr -d "'")
  run_test_show "OTA-09b" "Bundle version" "echo $BUNDLE_VER"

  run_test "OTA-09c" "Bundle compatible matches device" \
    "rauc info '$RAUCB' 2>/dev/null | grep -q 'haos-ihost'"

  echo "  NOTE: To run the full install test (OTA-09d..f), use:"
  echo "    rauc install $RAUCB && reboot"
  echo "  Then re-run this suite to verify post-OTA state."
  skip_test "OTA-09d" "RAUC install (manual step — see above)"
  skip_test "OTA-09e" "Post-OTA slot switch verified"
  skip_test "OTA-09f" "Persistent marker survived OTA"
else
  skip_test "OTA-09a..f" "No RAUCB_PATH set (set RAUCB_PATH=/path/to/bundle.raucb)"
fi

# --- OTA-10: Tampered bundle rejected ---
if [ -n "$RAUCB" ] && [ -f "$RAUCB" ]; then
  TAMPERED="/tmp/tampered_test.raucb"
  cp "$RAUCB" "$TAMPERED" 2>/dev/null
  echo "tampered" >> "$TAMPERED" 2>/dev/null
  run_test "OTA-10" "Tampered bundle rejected by RAUC" \
    "! rauc install '$TAMPERED' 2>/dev/null"
  rm -f "$TAMPERED"
else
  skip_test "OTA-10" "No RAUCB_PATH set"
fi

suite_end
