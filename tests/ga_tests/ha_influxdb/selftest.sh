#!/usr/bin/env bash
# selftest.sh — prove the ha_influxdb suite goes BOTH red and green, without a device.
#
# Drives tests/ga_tests/ha_influxdb/test.sh — the LIVE definition, not a copy —
# over fixture trees whose verdict is known in advance. docker and curl are
# shims (fixtures/shim/) answering from the fixture; Core's .storage is read by
# the suite itself through GA_HAIX_HA_DIR.
#
# must-fail-rc2-no-entry is BOSv1.4.0-rc2 as measured: Core with no influxdb
# config entry and no "°C" point in ga_homeassistant_db. base/ is the fixed
# device. Every other directory holds only the files that differ from base/.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="$HERE/test.sh"
FIXTURES="$HERE/fixtures"
export GA_HAIX_FIXTURE_BASE="$FIXTURES/base"
export GA_HAIX_TMP
GA_HAIX_TMP="$(mktemp -d)"
# Only the top-level shell cleans up: a command substitution must never remove
# the directory the next fixture run writes into.
trap '[[ "$BASHPID" == "$$" ]] && rm -rf "$GA_HAIX_TMP"' EXIT
fails=0; ran=0

[[ -f "$SUITE" ]] || { echo "FATAL: $SUITE missing"; exit 1; }
for tool in jq sed grep awk; do command -v "$tool" >/dev/null || { echo "FATAL: $tool missing"; exit 1; }; done

declare -A OUT
run() {
  local fx="$1" ha="$FIXTURES/base/ha"
  [[ -n "${OUT[$fx]:-}" ]] && return 0
  [[ -d "$FIXTURES/$fx" ]] || { echo "FATAL: fixture $fx missing"; exit 1; }
  [[ -d "$FIXTURES/$fx/ha" ]] && ha="$FIXTURES/$fx/ha"
  : > "$GA_HAIX_TMP/curl-args.log"
  # The fixture never changes, so one look is the whole truth: no wait.
  OUT[$fx]="$(PATH="$FIXTURES/shim:$PATH" GA_HAIX_FIXTURE="$FIXTURES/$fx" \
              GA_HAIX_HA_DIR="$ha" GA_HAIX_WAIT_S=0 sh "$SUITE" 2>&1)"
  cp "$GA_HAIX_TMP/curl-args.log" "$GA_HAIX_TMP/curl-args.$fx.log"
}
# verdict reads the cache only: it runs inside $(...), and a run there would
# cache into a subshell that is thrown away.
verdict() {
  local v
  v="$(printf '%s\n' "${OUT[$1]}" | sed 's/\x1b\[[0-9;]*m//g' | awk -v id="$2:" '$2==id {print $1; exit}')"
  echo "${v:-absent}"
}
expect() {
  local fixture="$1" id="$2" want="$3" got
  run "$fixture"
  got="$(verdict "$fixture" "$id")"; ran=$((ran + 1))
  if [[ "$got" == "$want" ]]; then echo "  ok    $fixture/$id → $got"
  else
    echo "  FAIL  $fixture/$id → $got (expected $want)"
    printf '%s\n' "${OUT[$fixture]}" | sed 's/^/          | /'; fails=$((fails + 1))
  fi
}
expect_detail() {
  local fixture="$1" want="$2"
  run "$fixture"; ran=$((ran + 1))
  if printf '%s\n' "${OUT[$fixture]}" | grep -qF -- "$want"; then echo "  ok    $fixture says: $want"
  else
    echo "  FAIL  $fixture does not say: $want"
    printf '%s\n' "${OUT[$fixture]}" | sed 's/^/          | /'; fails=$((fails + 1))
  fi
}

echo "== base (the fixed device — must NOT be flagged) =="
expect base HAIX-01 PASS
expect base HAIX-02 PASS
expect_detail base "newest \"°C\" point 60s behind Core's newest °C update (1 °C entities)"
# It asked ga_homeassistant_db for "°C", as the entry's own user — and the
# password reached curl only as a request field, never in the suite's output.
run base; ran=$((ran + 1))
if grep -qxF 'db=ga_homeassistant_db' "$GA_HAIX_TMP/curl-args.base.log" \
   && grep -qxF 'q=SELECT * FROM "°C" ORDER BY time DESC LIMIT 1' "$GA_HAIX_TMP/curl-args.base.log" \
   && grep -qxF 'u=ga_ha_influx_user' "$GA_HAIX_TMP/curl-args.base.log" \
   && ! printf '%s' "${OUT[base]}" | grep -qF 'CHANGEME-fixture-pw'; then
  echo "  ok    base/HAIX-02 asked ga_homeassistant_db.\"°C\" as ga_ha_influx_user; password not in the output"
else
  echo "  FAIL  base/HAIX-02 query or credential handling wrong:"; sed 's/^/          | /' "$GA_HAIX_TMP/curl-args.base.log"; fails=$((fails + 1))
fi

echo "== must-fail-rc2-no-entry (BOSv1.4.0-rc2: no entry, no point) =="
expect must-fail-rc2-no-entry HAIX-01 FAIL
expect must-fail-rc2-no-entry HAIX-02 FAIL
expect_detail must-fail-rc2-no-entry "no influxdb config entry in Core — Core writes nothing into ga_homeassistant_db (the rc2 shape)"
expect_detail must-fail-rc2-no-entry "Core has no InfluxDB entry — it cannot have written (the rc2 shape)"

echo "== must-fail-no-point (entry present, Core never wrote) =="
expect must-fail-no-point HAIX-01 PASS
expect must-fail-no-point HAIX-02 FAIL
expect_detail must-fail-no-point "no \"°C\" point in ga_homeassistant_db although Core has 1 °C entities"

echo "== must-fail-stale (newest point 2 h behind Core's newest °C update) =="
expect must-fail-stale HAIX-02 FAIL
expect_detail must-fail-stale "newest \"°C\" point is 120 min behind Core's newest °C update (max 15)"

echo "== must-fail-wrong-db (an entry, but not into ga_homeassistant_db) =="
expect must-fail-wrong-db HAIX-01 FAIL
expect_detail must-fail-wrong-db "entry writes into 'home_assistant', not ga_homeassistant_db"

echo "== must-skip-no-celsius (no °C entity: nothing for Core to write) =="
expect must-skip-no-celsius HAIX-01 PASS
expect must-skip-no-celsius HAIX-02 SKIP

echo
if [[ "$ran" -lt 17 ]]; then echo "FAIL: only $ran checks ran — coverage dropped"; exit 1; fi
if [[ "$fails" -gt 0 ]]; then echo "ha_influxdb selftest: $fails/$ran FAILED"; exit 1; fi
echo "ha_influxdb selftest: $ran/$ran as expected"
