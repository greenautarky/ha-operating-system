#!/bin/sh
# OTA / RAUC Update test suite - runs ON the device
#
# Fully automatic when RAUCB_PATH is set:
#   Phase 1: Validates bundle, installs, writes marker, reboots
#   Phase 2: After reboot, detects marker, verifies slot switch + data
#
# Usage:
#   sh test.sh                                        # Basic RAUC health checks
#   RAUCB_PATH=/mnt/data/update.raucb sh test.sh      # Phase 1: install + reboot
#   sh test.sh                                        # Phase 2: auto-detected post-OTA
#
# The marker file /mnt/data/.ota_test_phase tracks state:
#   absent  → normal run (health checks only)
#   phase1  → install done, reboot pending (set by Phase 1)
#   phase2  → post-reboot verification (detected automatically)
#
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "OTA Update"

OTA_MARKER="/mnt/data/.ota_test_phase"
OTA_DATA_MARKER="/mnt/data/.ota_test_data"
RAUCB="${RAUCB_PATH:-}"

# Detect which phase we're in
OTA_PHASE="health"
if [ -f "$OTA_MARKER" ]; then
  PHASE_CONTENT=$(cat "$OTA_MARKER" 2>/dev/null)
  if [ "$PHASE_CONTENT" = "phase1_done" ]; then
    OTA_PHASE="post_ota"
  fi
fi

# =========================================================================
# Health checks (always run)
# =========================================================================

run_test "OTA-01" "RAUC service available" \
  "command -v rauc >/dev/null 2>&1"

run_test "OTA-01b" "RAUC shows booted slot" \
  "rauc status 2>/dev/null | grep -q 'Booted from:'"

BOOTED_SLOT=$(rauc status 2>/dev/null | grep 'Booted from:' | grep -oE 'kernel\.[01]' || echo "unknown")
run_test_show "OTA-01c" "Booted slot" "echo $BOOTED_SLOT"

run_test "OTA-01d" "Both A/B slots present" \
  "rauc status 2>/dev/null | grep -q 'bootname.*A' && rauc status 2>/dev/null | grep -q 'bootname.*B'"

run_test "OTA-01e" "Booted slot status is good" \
  "rauc status 2>/dev/null | grep -A2 'booted' | grep -q 'good'"

COMPAT=$(rauc status 2>/dev/null | grep 'Compatible:' | awk '{print $2}')
run_test "OTA-02" "RAUC compatible is haos-ihost" \
  "[ '$COMPAT' = 'haos-ihost' ]"

VERSION_ID=$(grep 'VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2)
run_test_show "OTA-03" "OS version from os-release" "echo $VERSION_ID"

CPE_VER=$(grep 'CPE_NAME=' /etc/os-release 2>/dev/null | sed 's/.*haos://;s/:.*//')
run_test "OTA-03b" "CPE version matches VERSION_ID" \
  "[ '$VERSION_ID' = '$CPE_VER' ]"

run_test "OTA-04" "Data partition mounted" \
  "mountpoint -q /mnt/data"

run_test "OTA-04b" "Supervisor data present" \
  "test -d /mnt/data/supervisor"

run_test "OTA-05" "RAUC keyring certificate exists" \
  "test -f /etc/rauc/keyring.pem"

run_test "OTA-05b" "RAUC system.conf exists" \
  "test -f /etc/rauc/system.conf"

BOOT_COUNT=$(journalctl --list-boots 2>/dev/null | wc -l)
run_test "OTA-07" "Journal has boot history" \
  "[ $BOOT_COUNT -gt 0 ]"

for svc in telegraf fluent-bit netbird; do
  run_test "OTA-08-$svc" "Service $svc active" \
    "systemctl is-active $svc >/dev/null 2>&1"
done

# =========================================================================
# Phase 2: Post-OTA verification (after reboot from Phase 1)
# =========================================================================

if [ "$OTA_PHASE" = "post_ota" ]; then
  echo ""
  echo "  >>> POST-OTA VERIFICATION (Phase 2) <<<"
  echo ""

  # Read expected values from marker
  EXPECTED_SLOT=$(grep 'EXPECTED_SLOT=' "$OTA_MARKER" 2>/dev/null | cut -d= -f2)
  EXPECTED_VER=$(grep 'EXPECTED_VER=' "$OTA_MARKER" 2>/dev/null | cut -d= -f2)
  PRE_OTA_SLOT=$(grep 'PRE_OTA_SLOT=' "$OTA_MARKER" 2>/dev/null | cut -d= -f2)

  # OTA-09d: Slot switched
  run_test "OTA-09d" "Booted from NEW slot after OTA (was $PRE_OTA_SLOT, expect $EXPECTED_SLOT)" \
    "echo '$BOOTED_SLOT' | grep -q '$EXPECTED_SLOT'"

  # OTA-09e: Version matches bundle
  if [ -n "$EXPECTED_VER" ]; then
    run_test "OTA-09e" "OS version matches bundle ($EXPECTED_VER)" \
      "[ '$VERSION_ID' = '$EXPECTED_VER' ]"
  else
    skip_test "OTA-09e" "Expected version not recorded"
  fi

  # OTA-09f: Persistent data survived
  if [ -f "$OTA_DATA_MARKER" ]; then
    MARKER_CONTENT=$(cat "$OTA_DATA_MARKER" 2>/dev/null)
    run_test "OTA-09f" "Persistent data marker survived OTA" \
      "[ '$MARKER_CONTENT' = 'ota-test-data-integrity' ]"
  else
    run_test "OTA-09f" "Persistent data marker survived OTA" "false"
  fi

  # OTA-11: Rollback test — switch back to previous slot
  echo ""
  echo "  >>> ROLLBACK TEST <<<"
  echo ""

  run_test "OTA-11a" "Mark current slot as bad" \
    "rauc status mark-bad booted 2>/dev/null"

  ACTIVATED_AFTER=$(rauc status 2>/dev/null | grep 'Activated:' | grep -oE 'kernel\.[01]')
  run_test "OTA-11b" "Activated slot switched to $PRE_OTA_SLOT" \
    "[ '$ACTIVATED_AFTER' != '$BOOTED_SLOT' ]"

  # Write rollback marker and reboot
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
# Phase 3: Post-rollback verification
# =========================================================================

if [ -f "$OTA_MARKER" ] && grep -q "phase2_rollback" "$OTA_MARKER" 2>/dev/null; then
  echo ""
  echo "  >>> ROLLBACK VERIFICATION (Phase 3) <<<"
  echo ""

  EXPECTED_SLOT=$(grep 'EXPECTED_SLOT=' "$OTA_MARKER" 2>/dev/null | cut -d= -f2)
  ROLLBACK_FROM=$(grep 'ROLLBACK_FROM=' "$OTA_MARKER" 2>/dev/null | cut -d= -f2)

  run_test "OTA-11c" "Booted from OLD slot after rollback (expect $EXPECTED_SLOT)" \
    "echo '$BOOTED_SLOT' | grep -q '$EXPECTED_SLOT'"

  # OTA-11d: Data still intact after rollback
  if [ -f "$OTA_DATA_MARKER" ]; then
    run_test "OTA-11d" "Data marker survived rollback" \
      "[ '$(cat $OTA_DATA_MARKER)' = 'ota-test-data-integrity' ]"
  else
    run_test "OTA-11d" "Data marker survived rollback" "false"
  fi

  # Restore: re-activate the updated slot and mark good
  run_test "OTA-11e" "Re-activate updated slot ($ROLLBACK_FROM)" \
    "rauc status mark-good $ROLLBACK_FROM 2>/dev/null && rauc status mark-active $ROLLBACK_FROM 2>/dev/null"

  # Cleanup
  rm -f "$OTA_MARKER" "$OTA_DATA_MARKER"

  echo ""
  echo "  Rollback test complete. Rebooting to updated slot in 3s..."
  sleep 3
  suite_end
  reboot
  exit 0
fi

# =========================================================================
# Phase 1: Install bundle (only if RAUCB_PATH is set and no marker)
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

  # Install the real bundle
  echo ""
  echo "  Installing bundle..."
  if rauc install "$RAUCB" 2>&1 | grep -q "succeeded"; then
    run_test "OTA-09d-install" "RAUC install succeeded" "true"
  else
    run_test "OTA-09d-install" "RAUC install succeeded" "false"
    suite_end
    exit $_FAIL
  fi

  # Determine which slot we expect to boot from
  NEW_ACTIVATED=$(rauc status 2>/dev/null | grep 'Activated:' | grep -oE 'kernel\.[01]')

  # Write persistent data marker
  echo "ota-test-data-integrity" > "$OTA_DATA_MARKER"

  # Write phase marker with expected values
  echo "phase1_done" > "$OTA_MARKER"
  echo "PRE_OTA_SLOT=$BOOTED_SLOT" >> "$OTA_MARKER"
  echo "EXPECTED_SLOT=$NEW_ACTIVATED" >> "$OTA_MARKER"
  echo "EXPECTED_VER=$BUNDLE_VER" >> "$OTA_MARKER"

  echo ""
  echo "  Install complete. Rebooting to new slot ($NEW_ACTIVATED) in 3s..."
  echo "  After reboot, re-run this test to verify Phase 2 + rollback."
  sleep 3
  suite_end
  reboot
  exit 0
else
  skip_test "OTA-09..11" "Set RAUCB_PATH to run full OTA install + rollback test"
fi

suite_end
