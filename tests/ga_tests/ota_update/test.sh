#!/bin/sh
# OTA / RAUC Update test suite - runs ON the device
#
# Fully automatic when RAUCB_PATH is set:
#   Phase 1: Validate bundle, install, write markers, reboot
#   Phase 2: After reboot, verify slot switch + data, rollback, reboot
#   Phase 3: Verify rollback, restore updated slot, reboot
#
# Marker file /mnt/data/.ota_test_phase tracks state across reboots.
#
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "OTA Update"

OTA_MARKER="/mnt/data/.ota_test_phase"
OTA_DATA_MARKER="/mnt/data/.ota_test_data"
RAUCB="${RAUCB_PATH:-}"

BOOTED_SLOT=$(rauc status 2>/dev/null | grep 'Booted from:' | grep -oE 'kernel\.[01]' || echo "unknown")
VERSION_ID=$(grep 'VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2)

# =========================================================================
# Health checks (always run in every phase)
# =========================================================================

run_test "OTA-01" "RAUC service available" \
  "command -v rauc >/dev/null 2>&1"

run_test "OTA-01b" "RAUC shows booted slot" \
  "rauc status 2>/dev/null | grep -q 'Booted from:'"

run_test_show "OTA-01c" "Booted slot" "echo $BOOTED_SLOT"

run_test "OTA-01d" "Both A/B slots present" \
  "rauc status 2>/dev/null | grep -q 'bootname.*A' && rauc status 2>/dev/null | grep -q 'bootname.*B'"

run_test "OTA-01e" "Booted slot status is good" \
  "rauc status 2>/dev/null | grep -A2 'booted' | grep -q 'good'"

COMPAT=$(rauc status 2>/dev/null | grep 'Compatible:' | awk '{print $2}')
run_test "OTA-02" "RAUC compatible is haos-ihost" \
  "[ '$COMPAT' = 'haos-ihost' ]"

run_test_show "OTA-03" "OS version" "echo $VERSION_ID"

CPE_VER=$(grep 'CPE_NAME=' /etc/os-release 2>/dev/null | sed 's/.*haos://;s/:.*//')
run_test "OTA-03b" "CPE version matches VERSION_ID" \
  "[ '$VERSION_ID' = '$CPE_VER' ]"

run_test "OTA-04" "Data partition mounted" \
  "mountpoint -q /mnt/data"

run_test "OTA-04b" "Supervisor data present" \
  "test -d /mnt/data/supervisor"

run_test "OTA-05" "RAUC keyring exists" \
  "test -f /etc/rauc/keyring.pem"

run_test "OTA-07" "Journal has boot history" \
  "[ $(journalctl --list-boots 2>/dev/null | wc -l) -gt 0 ]"

for svc in telegraf fluent-bit netbird; do
  run_test "OTA-08-$svc" "Service $svc active" \
    "systemctl is-active $svc >/dev/null 2>&1"
done

# =========================================================================
# Detect phase from marker file (persists across reboots on /mnt/data)
# =========================================================================

if [ -f "$OTA_MARKER" ] && grep -q "phase2_rollback" "$OTA_MARKER" 2>/dev/null; then
  # =====================================================================
  # Phase 3: Post-rollback verification
  # =====================================================================
  echo ""
  echo "  >>> ROLLBACK VERIFICATION (Phase 3) <<<"
  echo ""

  EXPECTED_SLOT=$(grep 'EXPECTED_SLOT=' "$OTA_MARKER" 2>/dev/null | cut -d= -f2)
  ROLLBACK_FROM=$(grep 'ROLLBACK_FROM=' "$OTA_MARKER" 2>/dev/null | cut -d= -f2)

  run_test "OTA-11c" "Booted from OLD slot after rollback (expect $EXPECTED_SLOT)" \
    "echo '$BOOTED_SLOT' | grep -q '$EXPECTED_SLOT'"

  if [ -f "$OTA_DATA_MARKER" ]; then
    MARKER_VAL=$(cat "$OTA_DATA_MARKER" 2>/dev/null)
    run_test "OTA-11d" "Data marker survived rollback" \
      "[ '$MARKER_VAL' = 'ota-test-data-integrity' ]"
  else
    run_test "OTA-11d" "Data marker survived rollback" "false"
  fi

  run_test "OTA-11e" "Re-activate updated slot ($ROLLBACK_FROM)" \
    "rauc status mark-good $ROLLBACK_FROM 2>/dev/null && rauc status mark-active $ROLLBACK_FROM 2>/dev/null"

  # Cleanup markers
  rm -f "$OTA_MARKER" "$OTA_DATA_MARKER"

  echo ""
  echo "  Rollback test complete. Rebooting to updated slot in 3s..."
  sleep 3
  suite_end
  reboot
  exit 0

elif [ -f "$OTA_MARKER" ] && grep -q "phase1_done" "$OTA_MARKER" 2>/dev/null; then
  # =====================================================================
  # Phase 2: Post-OTA verification + rollback
  # =====================================================================
  echo ""
  echo "  >>> POST-OTA VERIFICATION (Phase 2) <<<"
  echo ""

  EXPECTED_SLOT=$(grep 'EXPECTED_SLOT=' "$OTA_MARKER" 2>/dev/null | cut -d= -f2)
  EXPECTED_VER=$(grep 'EXPECTED_VER=' "$OTA_MARKER" 2>/dev/null | cut -d= -f2)
  PRE_OTA_SLOT=$(grep 'PRE_OTA_SLOT=' "$OTA_MARKER" 2>/dev/null | cut -d= -f2)

  run_test "OTA-09d" "Booted from NEW slot (was $PRE_OTA_SLOT, now $EXPECTED_SLOT)" \
    "echo '$BOOTED_SLOT' | grep -q '$EXPECTED_SLOT'"

  if [ -n "$EXPECTED_VER" ]; then
    run_test "OTA-09e" "OS version matches bundle ($EXPECTED_VER)" \
      "[ '$VERSION_ID' = '$EXPECTED_VER' ]"
  else
    skip_test "OTA-09e" "Expected version not recorded"
  fi

  if [ -f "$OTA_DATA_MARKER" ]; then
    MARKER_VAL=$(cat "$OTA_DATA_MARKER" 2>/dev/null)
    run_test "OTA-09f" "Persistent data survived OTA" \
      "[ '$MARKER_VAL' = 'ota-test-data-integrity' ]"
  else
    run_test "OTA-09f" "Persistent data survived OTA" "false"
  fi

  # Rollback test
  echo ""
  echo "  >>> ROLLBACK TEST <<<"
  echo ""

  run_test "OTA-11a" "Mark current slot as bad" \
    "rauc status mark-bad booted 2>/dev/null"

  ACTIVATED_AFTER=$(rauc status 2>/dev/null | grep 'Activated:' | grep -oE 'kernel\.[01]')
  run_test "OTA-11b" "Activated slot switched away from $BOOTED_SLOT" \
    "[ '$ACTIVATED_AFTER' != '$BOOTED_SLOT' ]"

  # Write rollback marker
  echo "phase2_rollback" > "$OTA_MARKER"
  echo "EXPECTED_SLOT=$PRE_OTA_SLOT" >> "$OTA_MARKER"
  echo "ROLLBACK_FROM=$BOOTED_SLOT" >> "$OTA_MARKER"

  echo ""
  echo "  Rollback prepared. Rebooting in 3s..."
  sleep 3
  suite_end
  reboot
  exit 0

fi

# =========================================================================
# Phase 1: Install bundle (only if RAUCB_PATH set and no phase marker)
# =========================================================================

if [ -n "$RAUCB" ] && [ -f "$RAUCB" ]; then
  echo ""
  echo "  >>> OTA INSTALL TEST (Phase 1) <<<"
  echo ""

  run_test "OTA-09a" "RAUC bundle signature valid" \
    "rauc info '$RAUCB' 2>&1 | grep -q 'Verified'"

  BUNDLE_VER=$(rauc info "$RAUCB" 2>/dev/null | grep "Version:" | awk '{print $2}' | tr -d "'")
  run_test_show "OTA-09b" "Bundle version" "echo $BUNDLE_VER"

  run_test "OTA-09c" "Bundle compatible matches device" \
    "rauc info '$RAUCB' 2>/dev/null | grep -q 'haos-ihost'"

  # Tampered bundle test
  TAMPERED="/tmp/tampered_test.raucb"
  cp "$RAUCB" "$TAMPERED" 2>/dev/null
  echo "tampered" >> "$TAMPERED" 2>/dev/null
  run_test "OTA-10" "Tampered bundle rejected by RAUC" \
    "! rauc install '$TAMPERED' 2>/dev/null"
  rm -f "$TAMPERED"

  # Install
  echo ""
  echo "  Installing bundle..."
  if rauc install "$RAUCB" 2>&1 | grep -q "succeeded"; then
    run_test "OTA-09d-install" "RAUC install succeeded" "true"
  else
    run_test "OTA-09d-install" "RAUC install succeeded" "false"
    suite_end
    exit 1
  fi

  NEW_ACTIVATED=$(rauc status 2>/dev/null | grep 'Activated:' | grep -oE 'kernel\.[01]')

  # Write persistent markers
  echo "ota-test-data-integrity" > "$OTA_DATA_MARKER"
  echo "phase1_done" > "$OTA_MARKER"
  echo "PRE_OTA_SLOT=$BOOTED_SLOT" >> "$OTA_MARKER"
  echo "EXPECTED_SLOT=$NEW_ACTIVATED" >> "$OTA_MARKER"
  echo "EXPECTED_VER=$BUNDLE_VER" >> "$OTA_MARKER"

  echo ""
  echo "  Install complete. Rebooting to $NEW_ACTIVATED in 3s..."
  sleep 3
  suite_end
  reboot
  exit 0
else
  skip_test "OTA-09..11" "Set RAUCB_PATH to run full OTA install + rollback test"
fi

suite_end
