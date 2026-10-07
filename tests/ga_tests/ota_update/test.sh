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


# Tier-1 (error logs) and tier-2 (metrics) shippers are consent-gated by design:
# telegraf has ConditionPathExists=/mnt/data/.ga-consent-metrics, fluent-bit
# (tier-1) has ConditionPathExists=/mnt/data/.ga-consent-error_logs. Without the
# marker the unit is inactive on purpose and its env file does not exist. Tests
# that assert on them must SKIP with the reason, not FAIL — on a fresh device
# without consent they were 12 structural reds (2026-09-02, K31 rc19).
_consent_metrics()    { [ -f /mnt/data/.ga-consent-metrics ]; }
_consent_error_logs() { [ -f /mnt/data/.ga-consent-error_logs ]; }
for svc in telegraf fluent-bit fluent-bit-tier0 netbird; do
  case "$svc" in
    telegraf)   _consent_metrics    || { skip_test "OTA-08-$svc" "Service $svc active (tier-2 consent not given)"; continue; } ;;
    fluent-bit) _consent_error_logs || { skip_test "OTA-08-$svc" "Service $svc active (tier-1 consent not given)"; continue; } ;;
  esac
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
    "echo \"\$BOOTED_SLOT\" | grep -q '$EXPECTED_SLOT'"

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
    "echo \"\$BOOTED_SLOT\" | grep -q '$EXPECTED_SLOT'"

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

# ---------------------------------------------------------------------------
# OTA-12..16 — the SEAM: what this device would fetch if the fleet dispatched
# an update right now. Everything above tests RAUC on a bundle someone already
# put on the device; none of it looks at the URL the helper builds, and that is
# the half that broke in the field. Measured 2026-09-22: the production slot
# had served an eleven-week-old bundle the whole time, and every OTA check on
# every device was green throughout, because none of them asked the server
# anything.
#
# Read-only: HEAD requests and one small sidecar. Nothing is installed.
# ---------------------------------------------------------------------------
OTA_BASE="https://ota.greenautarky.com/releases/${VERSION_ID}"
DEV_RELEASE=$(head -1 /etc/ga-release 2>/dev/null | tr -d '[:space:]')
# Ask the server the way ga-rauc-install downloads: through the endpoint
# ga-resolve-ota pinned, never through name resolution. A check that resolves
# the name itself measures a path the download does not take.
OTA_PIN=$(head -c 64 /run/ga-resolve-ota.active 2>/dev/null | tr -d '[:space:]')
OTA_CURL="curl --resolve ota.greenautarky.com:443:${OTA_PIN:-unpinned}"

run_test "OTA-12" "the OTA host answers via the pinned endpoint" \
  "$OTA_CURL -fsS --max-time 20 -o /dev/null -w '%{http_code}' '$OTA_BASE/PROMOTED.json' | grep -q '^200$'"

run_test "OTA-13" "the production slot names the release it serves" \
  "$OTA_CURL -fsS --max-time 20 '$OTA_BASE/PROMOTED.json' | grep -q '\"ga_release\"'"

# The bundle a version-only dispatch would install must exist AND be the size
# its own checksum file describes a real file to be. A 404 here is a fleet that
# cannot update at all; both are silent until someone dispatches.
run_test "OTA-14" "the production bundle is downloadable" \
  "$OTA_CURL -fsS -I --max-time 30 '$OTA_BASE/haos_ihost-${VERSION_ID}.raucb' | grep -qi '200'"

run_test "OTA-15" "the production bundle ships its checksum" \
  "$OTA_CURL -fsS --max-time 20 '$OTA_BASE/haos_ihost-${VERSION_ID}.raucb.sha256' | grep -qE '^[0-9a-f]{64}  haos_ihost'"

# The rc slot for the release THIS device runs. A device on an rc whose slot
# was pruned cannot be re-installed or rolled forward without a re-stage — the
# check says so while it is cheap to fix, not during an incident.
if [ -n "$DEV_RELEASE" ]; then
  run_test "OTA-16" "this device's own release ($DEV_RELEASE) is still staged" \
    "$OTA_CURL -fsS -I --max-time 30 '$OTA_BASE/$DEV_RELEASE/haos_ihost-${VERSION_ID}.raucb' | grep -qi '200'"
else
  skip_test "OTA-16" "/etc/ga-release is empty — cannot ask for this device's slot"
fi

# OTA-17..20 — WHERE the download connects. ga-rauc-install fetches with
# `curl --resolve ota.greenautarky.com:443:<pin>` and the pin comes from
# /run/ga-resolve-ota.active. On the host, nsswitch asks systemd-resolved
# before /etc/hosts, so the hosts entry alone does not decide the address; only
# the pin does. These checks hold the device to the mesh path.
#
# in_mesh: first octet 100, second 64..127 (the CGNAT range the mesh uses).
in_mesh() {
  case "$1" in
    "" | *[!0-9.]* | *..* | .* | *. | *.*.*.*.* ) return 1 ;;
    *.*.*.* ) ;;
    * ) return 1 ;;
  esac
  _o1=${1%%.*}; _r=${1#*.}; _o2=${_r%%.*}
  [ "$_o1" = 100 ] && [ "$_o2" -ge 64 ] 2>/dev/null && [ "$_o2" -le 127 ]
}

run_test "OTA-17" "the pinned OTA endpoint is a mesh address (${OTA_PIN:-none})" \
  "in_mesh '$OTA_PIN'"

# Static, on the shipped helper: every curl in it pins the endpoint, and the
# pin is the resolver's file. A curl without --resolve would follow DNS.
RAUC_HELPER=/usr/sbin/ga-rauc-install
rauc_helper_pins() {
  grep -q '/run/ga-resolve-ota.active' "$RAUC_HELPER" || return 1
  _curls=$(grep -E '^[[:space:]]*(if ! )?curl ' "$RAUC_HELPER")
  [ -n "$_curls" ] || return 1          # zero curl lines inspected is a failure
  ! printf '%s\n' "$_curls" | grep -qv -- '--resolve "$OTA_RESOLVE"'
}
run_test "OTA-18" "ga-rauc-install downloads only through the pinned endpoint" \
  "rauc_helper_pins"

# The probe object the resolver asks for must be served through the pin: this
# is what makes the pin a measured choice rather than the first list entry.
OTA_PROBE=$( (. /etc/ga-services.conf; [ -f /mnt/data/ga-services.conf ] && . /mnt/data/ga-services.conf; echo "${GA_OTA_PROBE_PATH:-}") 2>/dev/null)
if [ -n "$OTA_PROBE" ]; then
  run_test "OTA-19" "the resolver's probe object ($OTA_PROBE) is served via the pin" \
    "$OTA_CURL -fsS --max-time 20 -o /dev/null 'https://ota.greenautarky.com$OTA_PROBE'"
else
  run_test "OTA-19" "ga-services.conf names the resolver's probe object (GA_OTA_PROBE_PATH)" "false"
fi

# Live: the connection a download would make lands on a mesh address. curl
# reports the peer it actually connected to, not the one it was told about.
OTA_PEER=$($OTA_CURL -sS --max-time 20 -o /dev/null -w '%{remote_ip}' "$OTA_BASE/PROMOTED.json" 2>/dev/null)
run_test "OTA-20" "an OTA download connects to a mesh address (peer ${OTA_PEER:-none})" \
  "in_mesh '$OTA_PEER'"

suite_end
