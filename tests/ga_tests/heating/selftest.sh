#!/usr/bin/env bash
# selftest.sh — prove the heating suite can go BOTH red and green, without a device.
#
# Runs tests/ga_tests/heating/test.sh — the LIVE definition, not a copy — over
# fixture trees whose verdict is known in advance. docker and curl are replaced
# by shims (fixtures/shim/) that answer from the fixture; the registries, the
# ga_heating store and the add-on options.json are read by the suite itself
# through GA_HEAT_HA_DIR / GA_HEAT_ADDON_DATA. Same reasoning as
# tests/ga_tests/provisioning/selftest.sh: a paste of failing output is
# evidence once, about one version; this is evidence on every run.
#
# must-pass is not padding: a suite that flags every device gets ignored, which
# is a slower way of having no suite at all — so the finished device is
# asserted green as hard as the broken ones are asserted red.
#
# Fixtures (tests/ga_tests/heating/fixtures/): base/ is the finished device
# (ga_heating 0.4.0 + engine 2.0.0, contract v1); every other directory holds
# ONLY the files that differ from base/ — the shims fall back to base/ per file.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="$HERE/test.sh"
FIXTURES="$HERE/fixtures"
export GA_HEAT_FIXTURE_BASE="$FIXTURES/base"
export GA_HEAT_TMP
GA_HEAT_TMP="$(mktemp -d)"
trap 'rm -rf "$GA_HEAT_TMP"' EXIT
fails=0
ran=0

[[ -x "$SUITE" ]] || { echo "FATAL: $SUITE missing or not executable"; exit 1; }
[[ -d "$FIXTURES/base" ]] || { echo "FATAL: $FIXTURES/base missing"; exit 1; }
for tool in jq sed grep; do command -v "$tool" >/dev/null || { echo "FATAL: $tool missing"; exit 1; }; done

# run <fixture> → suite output (cached per fixture; the suite is one process)
declare -A OUT
run() {
  local fx="$1"
  [[ -n "${OUT[$fx]:-}" ]] && return 0
  [[ -d "$FIXTURES/$fx" ]] || { echo "FATAL: fixture $fx missing"; exit 1; }
  local addon_data="$FIXTURES/base/addons-data"
  [[ -d "$FIXTURES/$fx/addons-data" ]] && addon_data="$FIXTURES/$fx/addons-data"
  : > "$GA_HEAT_TMP/curl-args.log"
  OUT[$fx]="$(PATH="$FIXTURES/shim:$PATH" GA_HEAT_FIXTURE="$FIXTURES/$fx" \
              GA_HEAT_HA_DIR="$FIXTURES/base/ha" GA_HEAT_ADDON_DATA="$addon_data" \
              sh "$SUITE" 2>&1)"
  cp "$GA_HEAT_TMP/curl-args.log" "$GA_HEAT_TMP/curl-args.$fx.log"
}

# verdict <fixture> <HEAT-id> → PASS|FAIL|SKIP|absent
verdict() {
  run "$1"
  local v
  v="$(printf '%s\n' "${OUT[$1]}" | awk -v id="$2:" '$2==id {print $1; exit}')"
  echo "${v:-absent}"
}

expect() {
  local fixture="$1" id="$2" want="$3" got
  got="$(verdict "$fixture" "$id")"
  ran=$((ran + 1))
  if [[ "$got" == "$want" ]]; then
    echo "  ok    $fixture/$id → $got"
  else
    echo "  FAIL  $fixture/$id → $got (expected $want)"
    printf '%s\n' "${OUT[$fixture]}" | grep -E "^ *(PASS|FAIL|SKIP) +$id:|-> " | sed 's/^/          | /'
    fails=$((fails + 1))
  fi
}
# expect_detail <fixture> <substring> — the FAIL/SKIP line must SAY WHY
expect_detail() {
  local fixture="$1" want="$2"
  run "$fixture"
  ran=$((ran + 1))
  if printf '%s\n' "${OUT[$fixture]}" | grep -qF -- "$want"; then
    echo "  ok    $fixture says: $want"
  else
    echo "  FAIL  $fixture does not say: $want"
    printf '%s\n' "${OUT[$fixture]}" | sed 's/^/          | /'
    fails=$((fails + 1))
  fi
}

echo "== base (finished device: ga_heating 0.4.0, engine 2.0.0 — must NOT be flagged) =="
for id in HEAT-00 HEAT-01 HEAT-02 HEAT-03 HEAT-04 HEAT-05 HEAT-06 HEAT-07 HEAT-08; do
  expect base "$id" PASS
done
# HEAT-07 asked for the room WITH a sensor and NOT for the valve-only room:
run base
ran=$((ran + 1))
if grep -qF "\"room\"='wohnzimmer'" "$GA_HEAT_TMP/curl-args.base.log" && ! grep -qF "'bad'" "$GA_HEAT_TMP/curl-args.base.log"; then
  echo "  ok    base/HEAT-07 queried room=wohnzimmer only (the valve-only room 'bad' was not asked)"
else
  echo "  FAIL  base/HEAT-07 query scope wrong:"; sed 's/^/          | /' "$GA_HEAT_TMP/curl-args.base.log"; fails=$((fails + 1))
fi

echo "== must-fail-calibration-no-source (ga_heating < 0.4.0 shape: entry without source) =="
expect must-fail-calibration-no-source HEAT-03 FAIL
expect_detail must-fail-calibration-no-source "no calibration{offset,written_at,source} for climate.0x0cae5ffffeab11e6"
expect must-fail-calibration-no-source HEAT-06 PASS   # the decision side is fine here

echo "== must-fail-decision-expired (valid_until in the past) =="
expect must-fail-decision-expired HEAT-06 FAIL
expect_detail must-fail-decision-expired "valid_until=2020-01-01T00:00:00 <= now="
expect must-fail-decision-expired HEAT-03 PASS

echo "== must-fail-decision-contract2 =="
expect must-fail-decision-contract2 HEAT-06 FAIL
expect_detail must-fail-decision-contract2 "contract=2 (want 1)"

echo "== must-fail-decision-missing (no sensor for one valve) =="
expect must-fail-decision-missing HEAT-06 FAIL
expect_detail must-fail-decision-missing "sensor.hm_0x0cae5ffffeab11e7_desired_offset absent"

echo "== must-fail-decision-unknown (state unknown — a retained discovery without a value) =="
expect must-fail-decision-unknown HEAT-06 FAIL
expect_detail must-fail-decision-unknown "state 'unknown' not numeric"

echo "== must-fail-liveness-stale (engine present, no hm_liveness row in 5m) =="
expect must-fail-liveness-stale HEAT-07 FAIL
expect_detail must-fail-liveness-stale "wohnzimmer: no hm_liveness row within 5m"
expect must-fail-liveness-stale HEAT-06 PASS

echo "== must-fail-liveness-refused (wrong credential → influx error) =="
expect must-fail-liveness-refused HEAT-07 FAIL
expect_detail must-fail-liveness-refused "influx refused"

echo "== must-fail-mqtt-storm-by-id (1.7.1 behaviour under the contract id: 24 connects) =="
expect must-fail-mqtt-storm-by-id HEAT-08 FAIL
expect_detail must-fail-mqtt-storm-by-id "24 with client id ga_hmvapp*"

echo "== must-fail-mqtt-storm-anon (1.7.1 behaviour under paho's random ids — caught by address) =="
expect must-fail-mqtt-storm-anon HEAT-08 FAIL
expect_detail must-fail-mqtt-storm-anon "1 with client id ga_hmvapp*, 25 from the engine's address"

echo "== must-skip-engine-young (engine up 4 min) =="
expect must-skip-engine-young HEAT-06 SKIP
expect_detail must-skip-engine-young "engine up < 15 min (Up 4 minutes)"
expect must-skip-engine-young HEAT-07 PASS

echo "== must-skip-no-engine (ga_hmvapp_addon not installed) =="
expect must-skip-no-engine HEAT-06 SKIP
expect must-skip-no-engine HEAT-07 SKIP
expect must-skip-no-engine HEAT-08 SKIP
expect_detail must-skip-no-engine "decision engine not installed — HEAT-06 needs ga_hmvapp_addon >= 2.0.0"
expect must-skip-no-engine HEAT-05 PASS

echo "== must-skip-no-cred (engine present, credential not delivered) =="
expect must-skip-no-cred HEAT-07 SKIP
expect_detail must-skip-no-cred "no credential path for local InfluxDB from the host"
expect must-skip-no-cred HEAT-06 PASS

# Fail closed on zero: a harness that inspected nothing is a failure, not a pass.
if (( ran == 0 )); then
  echo "FATAL: no expectations evaluated — fixtures or extraction broken"
  exit 1
fi

echo
if (( fails == 0 )); then
  echo "heating suite selftest: $ran/$ran expectations met (red AND green proven)"
  exit 0
fi
echo "heating suite selftest: $fails of $ran expectations FAILED"
exit 1
