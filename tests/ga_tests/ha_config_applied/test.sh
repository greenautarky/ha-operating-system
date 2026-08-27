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

# Read one key out of the `homeassistant:` block.
#
# `[^:]*:` and not `.*:` — the greedy form eats everything up to the LAST colon,
# so `internal_url: "http://kibu.local:8123"` yields `8123` and the comparison
# can never match. A check that cannot go green is as useless as one that cannot
# go red, and this one was caught only by deliberately making it pass.
cfg_value() {
  grep -E "^  $1:" "$CFG" 2>/dev/null | head -1 | sed "s/^[^:]*: *//" | tr -d '"' | tr -d '\r'
}

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
  want=$(cfg_value "$key")
  if [ -n "$want" ]; then
    run_test "HCA-09:$key" "Core runs the configured $key ($want)" \
      "grep -q '\"$key\": *$want' $CORE_CFG"
  else
    skip_test "HCA-09:$key" "$key not set in configuration.yaml"
  fi
done

for key in time_zone country; do
  want=$(cfg_value "$key")
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
# The urls: file vs Core, and the identity split (HCA-15..17)
# =========================================================================
# Added 2026-08-26 with ga_manager 0.133.0, which moved the urls onto the
# reconcile path. Before that they were written by converge alone — which runs
# once per device lifetime — so a device converged months earlier simply never
# had them. That is the state this suite could not see: it checked location,
# integrations and log levels, and said nothing about the two urls a resident
# and the fleet actually use to reach the device.
#
# internal_url derives from the live hostname, so it is asserted everywhere.
# external_url arrives with the identity at release, so a device without one is
# reported, not failed.

IDENT=$(cat /mnt/data/ga-identity.json 2>/dev/null || cat /mnt/data/supervisor/share/ga-identity.json 2>/dev/null)
URL_PREFIX=$(echo "$IDENT" | tr ',' '\n' | grep url_prefix | sed 's/.*: *"//;s/".*//')

want_int=$(cfg_value internal_url)
if [ -n "$want_int" ]; then
  run_test "HCA-15" "Core runs the configured internal_url ($want_int)" \
    "grep -q '\"internal_url\": *\"$want_int\"' $CORE_CFG"
else
  run_test "HCA-15" "internal_url is set in configuration.yaml" "false"
fi

# The url must name THIS device. A stale one points at whatever answers that
# mDNS name on the LAN — which, with two GA devices on one network, is the
# neighbour. That is the failure the per-device hostname exists to prevent, and
# it is invisible unless the url is compared to the live hostname.
# Three details here, each of which made this check unable to go green, and each
# found only by deliberately making it PASS rather than by reading it:
#   - `"hostname":` with the colon. Without it the grep also matches the entry
#     in the `features` list, `head -1` takes that one, and the value is empty.
#   - `^[^:]*:` and not `.*:` — the greedy form eats to the LAST colon.
#   - the newline strip, or the value arrives as "\nKiBu".
# A check that cannot go green is as useless as one that cannot go red.
HOSTNAME_NOW=$(docker exec "$GM" sh -c 'curl -fsS -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/host/info' 2>/dev/null \
  | tr ',' '\n' | grep '"hostname":' | head -1 | sed 's/^[^:]*: *"//;s/".*//' | tr -d '\n\r ')
if [ -z "$want_int" ]; then
  # HCA-15 already reports the missing url. Repeating it here would turn one
  # fault into two and hide how many things are actually wrong.
  skip_test "HCA-16" "no internal_url to compare — see HCA-15"
elif [ -n "$HOSTNAME_NOW" ]; then
  run_test "HCA-16" "internal_url matches the live hostname ($HOSTNAME_NOW), not a stale one" \
    "echo '$want_int' | grep -qi '://$HOSTNAME_NOW\.local:8123$'"
else
  skip_test "HCA-16" "Supervisor reported no hostname"
fi

if [ -n "$URL_PREFIX" ]; then
  want_ext=$(cfg_value external_url)
  run_test "HCA-17" "external_url names THIS device's prefix ($URL_PREFIX)" \
    "echo '$want_ext' | grep -q '://$URL_PREFIX\.'"
  if [ -n "$want_ext" ]; then
    run_test "HCA-17b" "Core runs the configured external_url" \
      "grep -q '\"external_url\": *\"$want_ext\"' $CORE_CFG"
  else
    skip_test "HCA-17b" "no external_url in configuration.yaml — see HCA-17"
  fi
else
  skip_test "HCA-17" "no url_prefix on this device yet — not released, external_url not due"
fi

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
