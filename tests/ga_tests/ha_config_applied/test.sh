#!/bin/sh
# HA Config Applied — runs ON the device, after provisioning.
#
# WHY THIS SUITE EXISTS
# =====================
# On 2026-08-19 six ga_manager releases went out in a day. Every defect in them
# was found by a device and none by the test suite, and they shared one shape:
# **a file that looked correct while Core ran something else.**
#
#   - ga_packages/ga_integrations.yaml written perfectly, the `packages:` key
#     that includes it deleted by the next write. Core lost all four GA
#     integrations. The file was flawless.
#   - The HA Core baseline written by converge only, so a device that had
#     already converged never received it — configuration.yaml simply had no
#     such keys, and nothing compared it to anything.
#   - A job reporting `core_reports: unknown` and an empty mismatch, which read
#     as "checked and agreed".
#
# So every assertion here reads Core's OWN state through the Supervisor proxy
# and compares it to what is on disk. Checking the files against each other
# would have passed on every one of those days.
#
# Run after provisioning, after an OTA, and after any reconcile.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "HA Config Applied"

HA_DIR="/mnt/data/supervisor/homeassistant"
CFG="$HA_DIR/configuration.yaml"
PKG_DIR="$HA_DIR/ga_packages"

# Core's own view, fetched once. The ga_manager container is the only place on
# the device holding a SUPERVISOR_TOKEN, so it is the route to Core's API — the
# same one ga_manager itself uses, which is the point: if this cannot ask, the
# add-on cannot either.
GM=$(docker ps --filter name=ga_manager --format '{{.Names}}' 2>/dev/null | head -1)
CORE_CFG=/tmp/ga-core-config.json
if [ -n "$GM" ]; then
  docker exec "$GM" sh -c \
    'curl -fsS -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/api/config' \
    > "$CORE_CFG" 2>/dev/null || : > "$CORE_CFG"
else
  : > "$CORE_CFG"
fi

# Helper: is a value present in Core's /api/config JSON?
core_has() { grep -q "$1" "$CORE_CFG" 2>/dev/null; }

# =========================================================================
# Reachability — everything below is meaningless without it (HCA-01..02)
# =========================================================================

run_test "HCA-01" "ga_manager container is running" \
  "test -n '$GM'"

# Fails rather than skips: this suite exists to compare Core's state to disk,
# and a run that silently checks only the disk half is the failure mode it was
# written for.
run_test "HCA-02" "Core /api/config is readable" \
  "test -s $CORE_CFG && grep -q components $CORE_CFG"

# =========================================================================
# configuration.yaml structure (HCA-03..05)
# =========================================================================

run_test "HCA-03" "configuration.yaml exists" \
  "test -f $CFG"

# Two blocks is a duplicate mapping key: the loader silently keeps the last, so
# half the settings vanish while the file looks fine.
run_test "HCA-04" "exactly one \`homeassistant:\` block" \
  "test \"\$(grep -c '^homeassistant:' $CFG 2>/dev/null)\" -eq 1"

# THE 2026-08-19 REGRESSION, verbatim: a package directory with content and no
# key including it. Core reads none of it and every file in there is inert.
run_test "HCA-05" "if ga_packages/ exists, configuration.yaml includes it" \
  "! test -d $PKG_DIR || grep -q 'packages: !include_dir_named ga_packages' $CFG"

# =========================================================================
# Integrations: DECLARED vs LOADED (HCA-06..08)
# =========================================================================
# The half that matters. A domain can be staged, placed, and declared, and Core
# can still have failed to set it up — which is exactly what a broken include
# looks like from the outside.

DECLARED=$(cat "$PKG_DIR/ga_integrations.yaml" 2>/dev/null | grep -E '^[a-z_]+:' | tr -d ':' )
STAGED=$(ls -1 /mnt/data/ga-custom-components 2>/dev/null || ls -1 /mnt/data/supervisor/share/ga-custom-components 2>/dev/null)

run_test "HCA-06" "at least one GA integration is declared" \
  "test -n '$DECLARED'"

# Every component the OS shipped must be declared. Catches the delivery half:
# a component staged by an OTA that nothing ever enabled.
for d in $STAGED; do
  run_test "HCA-07:$d" "staged component '$d' is declared for loading" \
    "echo '$DECLARED' | grep -qx '$d'"
done

# Every declared domain must be LOADED IN CORE. This is the assertion that
# would have gone red within a minute on 2026-08-19.
for d in $DECLARED; do
  run_test "HCA-08:$d" "Core reports '$d' as loaded" \
    "grep -q '\"$d\"' $CORE_CFG"
done

# =========================================================================
# Site config: file vs what Core is RUNNING ON (HCA-09..12)
# =========================================================================
# They disagree for exactly as long as it takes Core to restart — and a device
# left in that state computes every sunrise for the previous location.

for key in latitude longitude elevation; do
  want=$(grep -E "^  $key:" "$CFG" 2>/dev/null | head -1 | sed 's/.*: *//' | tr -d '"')
  if [ -n "$want" ]; then
    run_test "HCA-09:$key" "Core runs the configured $key ($want)" \
      "grep -q '\"$key\": *$want' $CORE_CFG"
  else
    skip_test "HCA-09:$key" "$key not set in configuration.yaml"
  fi
done

for key in time_zone country; do
  want=$(grep -E "^  $key:" "$CFG" 2>/dev/null | head -1 | sed 's/.*: *//' | tr -d '"')
  if [ -n "$want" ]; then
    run_test "HCA-10:$key" "Core runs the configured $key ($want)" \
      "grep -q '\"$key\": *\"$want\"' $CORE_CFG"
  else
    skip_test "HCA-10:$key" "$key not set in configuration.yaml"
  fi
done

# `config_source: yaml` is how Core says the YAML won. If it says `storage`,
# our file is being ignored and every check above compared two copies of the
# same stale value.
run_test "HCA-11" "Core reports config_source=yaml (our file is authoritative)" \
  "grep -q '\"config_source\": *\"yaml\"' $CORE_CFG"

# =========================================================================
# Log levels + the disclosure coupling (HCA-12..13)
# =========================================================================

run_test "HCA-12" "ga_logger.yaml present (HA log levels managed)" \
  "test -f $PKG_DIR/ga_logger.yaml"

# NOT a failure — a raised level is a legitimate operator choice. But it becomes
# a disclosure together with fluent-bit's parked HA input, and nobody checks the
# two together, so the pair is surfaced here where someone is already looking.
if grep -qE '^\s+(default|custom_components): *(debug|trace)' "$PKG_DIR/ga_logger.yaml" 2>/dev/null; then
  if [ -f /mnt/data/fluent-bit/override.conf ] && \
     grep -q 'homeassistant.log' /mnt/data/fluent-bit/override.conf 2>/dev/null; then
    run_test "HCA-13" "log levels raised AND HA log shipping enabled — MQTT payloads and entity states are leaving this device" \
      "false"
  else
    warn_test "HCA-13" "HA log levels raised on this device (local only — fluent-bit HA input is parked)"
  fi
else
  run_test "HCA-13" "HA log levels at the fleet default" "true"
fi

# =========================================================================
# The device's own verdict (HCA-14)
# =========================================================================
# ga_manager already verifies its own applied state. Running it here means one
# command after provisioning answers both "is the device configured" and "does
# Core agree" — and a disagreement between this suite and that check is itself
# information.

if [ -n "$GM" ]; then
  TOKEN=$(docker exec "$GM" cat /data/auth.token 2>/dev/null)
  PV=$(docker exec "$GM" sh -c \
    "curl -fsS -H 'Authorization: Bearer $TOKEN' -X POST -H 'Content-Type: application/json' \
     -d '{}' http://127.0.0.1:8099/jobs/provision-verify" 2>/dev/null)
  if [ -n "$PV" ]; then
    sleep 20
    RES=$(docker exec "$GM" sh -c \
      "curl -fsS -H 'Authorization: Bearer $TOKEN' http://127.0.0.1:8099/provision-verify" 2>/dev/null)
    echo "$RES" > /tmp/ga-provision-verify.json
    run_test "HCA-14" "provision-verify reports no failures" \
      "grep -q '\"passed\": *true' /tmp/ga-provision-verify.json"
  else
    skip_test "HCA-14" "could not dispatch provision-verify"
  fi
else
  skip_test "HCA-14" "ga_manager container absent"
fi

suite_end
