#!/bin/sh
# check_phase_invariants.sh — grade the converge PHASE invariants of a device.
#
# WHY A SEPARATE SCRIPT
# ---------------------
# These checks need to be provable without a device. The device suite runs them
# against the real root; tests/ga_tests/provisioning/selftest.sh runs THIS SAME
# FILE against fixture trees whose correct verdict is known in advance, so the
# checks cannot rot into decoration. A self-test that re-implemented the logic
# would test a copy and stay green while the real check drifted — the exact
# failure class tests/gates/run_gate_selftests.sh exists to prevent.
#
# WHAT IT CHECKS
# --------------
# Convergence has two preconditions, so ga_manager 0.108.0+ has two markers:
# `.ga_converged_base` for the offline baseline and `.ga_converged` for baseline
# PLUS the per-device steps that need the fleet-assigned identity. Before that
# there was one marker, written even when the per-device steps had been skipped.
# Measured on K31 (2026-08-17, fresh flash of BOSv1.3.0-rc1): converge held the
# single job runner for ten minutes installing add-ons, so the fleet-manager's
# identity-write queued behind it and landed nine seconds AFTER the marker was
# written. The device reported "converged" — and a PASSING self-check — while
# holding no device_id, no url_prefix and no PIN.
#
# So every check here asserts the marker's CLAIM against the device's actual
# state. That works on any ga_manager version.
#
# USAGE
#   check_phase_invariants.sh [ROOT]        # ROOT defaults to "" (= the real /)
#
# Prints one line per check:  <id> <pass|fail|skip> <detail>
# Always exits 0 — grading belongs to the caller (the device suite maps the
# lines onto run_test/skip_test; the self-test compares them to expectations).

ROOT="${1:-}"

SHARE="$ROOT/mnt/data/supervisor/share"
HA_CFG="$ROOT/mnt/data/supervisor/homeassistant"
MARK_FULL="$SHARE/.ga_converged"
MARK_BASE="$SHARE/.ga_converged_base"
IDENTITY="$SHARE/ga-identity.json"
PIN_CANON="$HA_CFG/.storage/greenautarky_secrets/onboarding_pin"
PIN_COMPAT="$HA_CFG/ga-onboarding-pin"
GM_DATA=$(ls -d "$ROOT"/mnt/data/supervisor/addons/data/*ga_manager 2>/dev/null | head -1)

emit() { printf '%s %s %s\n' "$1" "$2" "$3"; }

# ── PROV-07: the baseline marker ────────────────────────────────────────
if [ -f "$MARK_BASE" ]; then
  emit PROV-07 pass "baseline marker present"
elif [ -f "$MARK_FULL" ]; then
  # A fully converged device from before 0.108.0 has no baseline marker and
  # never will. Skipping is honest here: the stronger claim (PROV-08) still runs.
  emit PROV-07 skip "ga_manager older than 0.108.0 (single-marker converge, full marker present)"
else
  emit PROV-07 fail "neither marker present — converge has not completed a phase"
fi

# ── PROV-08: a converged device HAS its identity ─────────────────────────
# This is the false-green the single marker allowed, and the reason this file
# exists. jq is present on the device image; without it, fail rather than skip
# (a check that quietly disappears is worse than one that is loud about being
# unable to run).
if [ -f "$MARK_FULL" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    emit PROV-08 fail "jq unavailable — cannot verify the identity of a device claiming convergence"
  elif jq -e '(.device_id // "") != "" and (.url_prefix // "") != ""' "$IDENTITY" >/dev/null 2>&1; then
    emit PROV-08 pass "device_id + url_prefix present in ga-identity.json"
  else
    emit PROV-08 fail "device claims .ga_converged but ga-identity.json lacks device_id/url_prefix"
  fi
elif [ -f "$MARK_BASE" ]; then
  # Baseline done, per-device phase outstanding. Red on purpose: a device left
  # half-provisioned is a defect, not a state to skip past.
  emit PROV-08 fail "per-device phase outstanding (baseline converged, no identity yet)"
else
  emit PROV-08 fail "converge has not run (neither marker present)"
fi

# ── PROV-09: the onboarding PIN ─────────────────────────────────────────
# Without it the wizard skips its PIN step, so the device looks onboarded
# while having asked nobody.
if [ -f "$MARK_FULL" ]; then
  if [ -s "$PIN_CANON" ] || [ -s "$PIN_COMPAT" ]; then
    emit PROV-09 pass "onboarding PIN present on disk"
  else
    emit PROV-09 fail "converged device has no onboarding PIN — the wizard will skip its PIN step"
  fi
else
  emit PROV-09 skip "device not converged — PROV-08 already reports that defect"
fi

# ── PROV-10: no unreported admin password parked on the device ──────────
# ga_manager parks a generated admin password when it cannot report it. A file
# still sitting there means the fleet-manager never got it, i.e. the device
# holds the only copy of a live admin credential.
if [ -n "$GM_DATA" ]; then
  if [ -f "$GM_DATA/ga-generated-admin-pw" ]; then
    emit PROV-10 fail "generated admin password still parked in $GM_DATA — never reported to the fleet-manager"
  else
    emit PROV-10 pass "no unreported admin password parked"
  fi
else
  emit PROV-10 fail "ga_manager addon data dir not found — cannot check for a parked password"
fi
