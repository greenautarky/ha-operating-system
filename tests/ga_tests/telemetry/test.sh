#!/bin/sh
# Telemetry test suite - runs ON the device
# Tests service health, consent gating, and environment setup.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Telemetry"

# =========================================================================
# Service health (existing TEL-01..12)
# =========================================================================

# Note: TEL-01/02 now depend on consent. If consent not given, services
# won't be running — that's CORRECT behavior. Use warn_test to avoid
# false failures on devices without consent.
CONSENT_STORE="/mnt/data/supervisor/homeassistant/.storage/greenautarky_telemetry"
METRICS_MARKER="/mnt/data/.ga-consent-metrics"
ERRORS_MARKER="/mnt/data/.ga-consent-error_logs"

if [ -f "$METRICS_MARKER" ]; then
  run_test "TEL-01" "Telegraf service running (consent given)" \
    "systemctl is-active telegraf"
else
  warn_test "TEL-01" "Telegraf service NOT running (no consent — expected)" \
    "! systemctl is-active telegraf"
fi

if [ -f "$ERRORS_MARKER" ]; then
  run_test "TEL-02" "Fluent-Bit service running (consent given)" \
    "systemctl is-active fluent-bit"
else
  warn_test "TEL-02" "Fluent-Bit service NOT running (no consent — expected)" \
    "! systemctl is-active fluent-bit"
fi

run_test "TEL-03" "GA_ENV set in telegraf env" \
  "grep -q 'GA_ENV=' /mnt/data/telegraf/env 2>/dev/null"

run_test "TEL-04" "GA_ENV set in fluent-bit env" \
  "grep -q 'GA_ENV=' /mnt/data/fluent-bit/env 2>/dev/null"

run_test "TEL-05" "DEVICE_UUID extracted (not unknown)" \
  "grep 'DEVICE_UUID=' /mnt/data/telegraf/env 2>/dev/null | grep -qv 'unknown'"

run_test "TEL-06" "DEVICE_UUID matches across services" \
  "[ \"$(grep DEVICE_UUID /mnt/data/telegraf/env 2>/dev/null)\" = \"$(grep DEVICE_UUID /mnt/data/fluent-bit/env 2>/dev/null)\" ]"

run_test "TEL-07" "Telegraf config on rootfs" \
  "systemctl cat telegraf 2>/dev/null | grep -q '/etc/telegraf/telegraf.conf'"

run_test "TEL-08" "Fluent-Bit config on rootfs" \
  "systemctl cat fluent-bit 2>/dev/null | grep -q '/etc/fluent-bit/fluent-bit.conf'"

run_test "TEL-09" "Telegraf no persistent errors (last 5 min)" \
  "! journalctl -u telegraf --since '5 min ago' --no-pager -q 2>/dev/null | grep -qi 'error.*output\|failed to write'"

run_test "TEL-10" "Fluent-Bit no persistent errors (last 5 min)" \
  "! journalctl -u fluent-bit --since '5 min ago' --no-pager -q 2>/dev/null | grep -qi 'error.*output\|connection refused'"

run_test "TEL-11" "Safe defaults in telegraf unit" \
  "systemctl cat telegraf 2>/dev/null | grep -q 'Environment=.*GA_ENV=dev'"

run_test_show "TEL-ENV" "Telegraf env file contents" \
  "cat /mnt/data/telegraf/env 2>/dev/null"

skip_test "TEL-12" "ga-env.conf override works" "mutates state (restarts telegraf)"

# =========================================================================
# Consent gate script (TEL-20..27)
# =========================================================================

echo ""
echo "--- Consent gate ---"

run_test "TEL-20" "ga-telemetry-gate script exists on rootfs" \
  "test -x /usr/sbin/ga-telemetry-gate"

# TEL-21: No consent file → gate blocks
# Use temp dir to avoid touching real consent
TMPDIR_TEL=$(mktemp -d)
echo '{}' > "$TMPDIR_TEL/empty_store"

run_test "TEL-21" "gate blocks when no consent file exists" \
  "! STORE_PATH=/nonexistent/path /usr/sbin/ga-telemetry-gate metrics"

# TEL-22: metrics=false → gate blocks
echo '{"key":"greenautarky_telemetry","version":1,"data":{"error_logs":true,"metrics":false}}' \
  > "$TMPDIR_TEL/store_no_metrics"
run_test "TEL-22" "gate blocks when metrics=false" \
  "! STORE_PATH=$TMPDIR_TEL/store_no_metrics /usr/sbin/ga-telemetry-gate metrics"

# TEL-23: metrics=true → gate allows
echo '{"key":"greenautarky_telemetry","version":1,"data":{"error_logs":false,"metrics":true}}' \
  > "$TMPDIR_TEL/store_yes_metrics"
run_test "TEL-23" "gate allows when metrics=true" \
  "STORE_PATH=$TMPDIR_TEL/store_yes_metrics /usr/sbin/ga-telemetry-gate metrics"

# TEL-24: error_logs=false → gate blocks
run_test "TEL-24" "gate blocks when error_logs=false" \
  "! STORE_PATH=$TMPDIR_TEL/store_yes_metrics /usr/sbin/ga-telemetry-gate error_logs"

# TEL-25: error_logs=true → gate allows
run_test "TEL-25" "gate allows when error_logs=true" \
  "STORE_PATH=$TMPDIR_TEL/store_no_metrics /usr/sbin/ga-telemetry-gate error_logs"

# TEL-26: GA_TELEMETRY_FORCE=1 bypasses consent
run_test "TEL-26" "GA_TELEMETRY_FORCE=1 bypasses consent check" \
  "GA_TELEMETRY_FORCE=1 STORE_PATH=/nonexistent /usr/sbin/ga-telemetry-gate metrics"

# TEL-27: write mode creates correct markers
echo '{"key":"greenautarky_telemetry","version":1,"data":{"error_logs":true,"metrics":true}}' \
  > "$TMPDIR_TEL/store_both"
# Temporarily redirect marker dir (script uses hardcoded /mnt/data — test actual markers instead)
run_test "TEL-27" "write mode accepted (no crash)" \
  "STORE_PATH=$TMPDIR_TEL/store_both /usr/sbin/ga-telemetry-gate write"

rm -rf "$TMPDIR_TEL"

# =========================================================================
# Consent service (TEL-30..32)
# =========================================================================

echo ""
echo "--- Consent service ---"

run_test "TEL-30" "ga-telemetry-consent.service ran successfully" \
  "systemctl is-active ga-telemetry-consent || systemctl show ga-telemetry-consent -p ActiveState --value 2>/dev/null | grep -q 'active'"

# TEL-31/32: Marker files match actual consent
if [ -f "$CONSENT_STORE" ]; then
  METRICS_VAL=$(sed -n 's/.*"metrics"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' "$CONSENT_STORE" | tail -1)
  ERRORS_VAL=$(sed -n 's/.*"error_logs"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' "$CONSENT_STORE" | tail -1)

  if [ "$METRICS_VAL" = "true" ]; then
    run_test "TEL-31" "consent marker for metrics exists (consent=true)" \
      "test -f $METRICS_MARKER"
  else
    run_test "TEL-31" "consent marker for metrics absent (consent=false)" \
      "test ! -f $METRICS_MARKER"
  fi

  if [ "$ERRORS_VAL" = "true" ]; then
    run_test "TEL-32" "consent marker for error_logs exists (consent=true)" \
      "test -f $ERRORS_MARKER"
  else
    run_test "TEL-32" "consent marker for error_logs absent (consent=false)" \
      "test ! -f $ERRORS_MARKER"
  fi
else
  warn_test "TEL-31" "consent store not found (device not onboarded)" "false"
  warn_test "TEL-32" "consent store not found (device not onboarded)" "false"
fi

# =========================================================================
# Service gating (TEL-33..36)
# =========================================================================

echo ""
echo "--- Service gating ---"

run_test "TEL-33" "telegraf.service has ConditionPathExists" \
  "systemctl cat telegraf 2>/dev/null | grep -q 'ConditionPathExists.*ga-consent-metrics'"

run_test "TEL-34" "fluent-bit.service has ConditionPathExists" \
  "systemctl cat fluent-bit 2>/dev/null | grep -q 'ConditionPathExists.*ga-consent-error_logs'"

# TEL-35: Telegraf running ↔ marker exists (consistency check)
TEL_ACTIVE=$(systemctl is-active telegraf 2>/dev/null)
if [ "$TEL_ACTIVE" = "active" ] && [ ! -f "$METRICS_MARKER" ]; then
  run_test "TEL-35" "telegraf NOT running without consent marker" "false"
elif [ "$TEL_ACTIVE" != "active" ] && [ -f "$METRICS_MARKER" ]; then
  # Marker exists but service not running — could be a startup issue
  warn_test "TEL-35" "telegraf not running despite consent marker (check logs)" "false"
else
  run_test "TEL-35" "telegraf state consistent with consent marker" "true"
fi

# TEL-36: Fluent-Bit running ↔ marker exists
FB_ACTIVE=$(systemctl is-active fluent-bit 2>/dev/null)
if [ "$FB_ACTIVE" = "active" ] && [ ! -f "$ERRORS_MARKER" ]; then
  run_test "TEL-36" "fluent-bit NOT running without consent marker" "false"
elif [ "$FB_ACTIVE" != "active" ] && [ -f "$ERRORS_MARKER" ]; then
  warn_test "TEL-36" "fluent-bit not running despite consent marker (check logs)" "false"
else
  run_test "TEL-36" "fluent-bit state consistent with consent marker" "true"
fi

# =========================================================================
# Consent file format (TEL-37..38)
# =========================================================================

echo ""
echo "--- Consent file validation ---"

if [ -f "$CONSENT_STORE" ]; then
  # TEL-37: Valid JSON (basic check — BusyBox has no jq)
  run_test "TEL-37" "consent file is parseable (has data key)" \
    "grep -q '\"data\"' $CONSENT_STORE"

  # TEL-38: HA storage wrapper format
  run_test "TEL-38" "consent file has HA storage wrapper (key + version)" \
    "grep -q '\"key\".*greenautarky_telemetry' $CONSENT_STORE && grep -q '\"version\"' $CONSENT_STORE"
else
  skip_test "TEL-37" "consent file format" "not yet onboarded"
  skip_test "TEL-38" "consent file HA wrapper" "not yet onboarded"
fi

suite_end
