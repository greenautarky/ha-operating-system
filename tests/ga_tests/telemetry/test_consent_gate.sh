#!/bin/sh
# Tests for ga-telemetry-gate (Privacy Tier Phase B).
#
# Runs the script against fixture storage files in /tmp, verifies
# exit codes + marker-file production. Independent of any device.
#
# Run from repo root:
#   sh tests/ga_tests/telemetry/test_consent_gate.sh

set -u

GATE="${GATE:-$(dirname "$0")/../../../buildroot-ihost/rootfs-overlay/usr/sbin/ga-telemetry-gate}"
WORK="$(mktemp -d -t consent-gate-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -x "$GATE" ]; then
    # Treat non-executable as still-testable (it's a /bin/sh script)
    if [ ! -f "$GATE" ]; then
        echo "FAIL: gate script not found at $GATE"
        exit 1
    fi
fi

pass=0
fail=0
PASS() { echo "  PASS  $1"; pass=$((pass+1)); }
FAIL() { echo "  FAIL  $1 ($2)"; fail=$((fail+1)); }

# Helper: run the gate, return exit code
run_gate() {
    STORE_PATH="$1" POLICY_VERSION_FILE="$2" MARKER_DIR="$3" sh "$GATE" "$4" >/dev/null 2>&1
}

# Helper: assert exit code
assert_exit() {
    actual=$1
    expected=$2
    name=$3
    if [ "$actual" -eq "$expected" ]; then
        PASS "$name (exit $actual)"
    else
        FAIL "$name" "expected exit $expected, got $actual"
    fi
}

echo ""
echo "=== ga-telemetry-gate tests ==="

# ---------------------------------------------------------------------------
# Fixture 1: v1 schema, tier1=true tier2=false, policy_version=1
# ---------------------------------------------------------------------------
echo "--- v1 schema ---"
cat > "$WORK/store-v1.json" <<EOF
{"version":1,"minor_version":1,"key":"greenautarky_telemetry","data":{"error_logs":true,"metrics":false}}
EOF
echo "1" > "$WORK/policy"

run_gate "$WORK/store-v1.json" "$WORK/policy" "$WORK/m" tier1
assert_exit $? 0 "v1 tier1 (alias error_logs=true) → consent given"

run_gate "$WORK/store-v1.json" "$WORK/policy" "$WORK/m" tier2
assert_exit $? 1 "v1 tier2 (alias metrics=false) → withheld"

run_gate "$WORK/store-v1.json" "$WORK/policy" "$WORK/m" error_logs
assert_exit $? 0 "v1 error_logs (legacy alias) → consent given"

run_gate "$WORK/store-v1.json" "$WORK/policy" "$WORK/m" metrics
assert_exit $? 1 "v1 metrics (legacy alias) → withheld"

# ---------------------------------------------------------------------------
# Fixture 2: v2 schema with policy_version_accepted=1
# ---------------------------------------------------------------------------
echo "--- v2 schema ---"
cat > "$WORK/store-v2.json" <<EOF
{
  "version": 2,
  "minor_version": 0,
  "key": "greenautarky_telemetry",
  "data": {
    "policy_version_accepted": 1,
    "tiers": {
      "tier1": {"value": true,  "accepted_at": "2026-05-15T15:00:00Z", "policy_version": 1},
      "tier2": {"value": false, "accepted_at": "2026-05-15T15:00:00Z", "policy_version": 1}
    }
  }
}
EOF

run_gate "$WORK/store-v2.json" "$WORK/policy" "$WORK/m" tier1
assert_exit $? 0 "v2 tier1=true → consent given"

run_gate "$WORK/store-v2.json" "$WORK/policy" "$WORK/m" tier2
assert_exit $? 1 "v2 tier2=false → withheld"

# ---------------------------------------------------------------------------
# Fixture 3: Policy bump — baked > accepted → stale
# ---------------------------------------------------------------------------
echo "--- Policy version bump (stale) ---"
echo "2" > "$WORK/policy"
run_gate "$WORK/store-v2.json" "$WORK/policy" "$WORK/m" tier1
assert_exit $? 1 "Baked=2 > accepted=1 → tier1 withheld even though value=true (stale)"

run_gate "$WORK/store-v2.json" "$WORK/policy" "$WORK/m" tier2
assert_exit $? 1 "Baked=2 > accepted=1 → tier2 also withheld"

# ---------------------------------------------------------------------------
# Fixture 4: No consent file
# ---------------------------------------------------------------------------
echo "--- Missing store file ---"
echo "1" > "$WORK/policy"
run_gate "$WORK/no-such-file.json" "$WORK/policy" "$WORK/m" tier1
assert_exit $? 1 "Missing store → tier1 withheld"

# ---------------------------------------------------------------------------
# Fixture 5: write mode produces both new and legacy markers
# ---------------------------------------------------------------------------
echo "--- write mode produces tier + legacy markers ---"
mkdir -p "$WORK/m"
rm -f "$WORK/m"/.ga-consent-*
run_gate "$WORK/store-v2.json" "$WORK/policy" "$WORK/m" write
if [ -f "$WORK/m/.ga-consent-tier1" ] && [ -f "$WORK/m/.ga-consent-error_logs" ]; then
    PASS "write produces both .ga-consent-tier1 AND legacy .ga-consent-error_logs"
else
    FAIL "write should produce tier1 + error_logs markers" "found: $(ls "$WORK/m" | tr '\n' ',')"
fi
if [ -f "$WORK/m/.ga-consent-tier2" ] || [ -f "$WORK/m/.ga-consent-metrics" ]; then
    FAIL "write should NOT produce tier2/metrics markers (tier2=false in fixture)" "found tier2/metrics marker"
else
    PASS "write correctly omits tier2 markers when value=false"
fi

# ---------------------------------------------------------------------------
# Fixture 6: write mode after policy bump → no markers
# ---------------------------------------------------------------------------
echo "--- write under policy bump → no markers ---"
echo "2" > "$WORK/policy"
rm -f "$WORK/m"/.ga-consent-*
touch "$WORK/m/.ga-consent-tier1" "$WORK/m/.ga-consent-error_logs"  # stale markers
run_gate "$WORK/store-v2.json" "$WORK/policy" "$WORK/m" write
if [ -f "$WORK/m/.ga-consent-tier1" ] || [ -f "$WORK/m/.ga-consent-error_logs" ]; then
    FAIL "policy stale → markers should be REMOVED, not kept" ""
else
    PASS "policy stale → write removes existing markers (forces re-consent)"
fi

# ---------------------------------------------------------------------------
# Fixture 7: GA_TELEMETRY_FORCE bypass
# ---------------------------------------------------------------------------
echo "--- GA_TELEMETRY_FORCE dev bypass ---"
echo "GA_TELEMETRY_FORCE=1" > "$WORK/ga-env.conf"
# Run the gate with the GA env loading the override
GA_TELEMETRY_FORCE=1 STORE_PATH="$WORK/no-such-file.json" POLICY_VERSION_FILE="$WORK/policy" \
    MARKER_DIR="$WORK/m" sh "$GATE" tier2 >/dev/null 2>&1
assert_exit $? 0 "GA_TELEMETRY_FORCE=1 bypasses missing store + policy bump"

# ---------------------------------------------------------------------------
echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
