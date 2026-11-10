#!/bin/bash
# selftest.sh - the health suite's required-add-on check (ga_require_addons) is red AND green
# without a device. Drives the LIVE test.sh with a docker shim answering `docker ps` from
# fixtures/<name>/containers.txt; only the HLTH-REQ-* verdicts are judged (the rest of the
# suite needs a device). must-pass-addon-prefix is the BOSv1.5.x naming fallback.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0; ran=0
verdict() {  # verdict <fixture> <id>
  PATH="$HERE/fixtures/shim:$PATH" GA_HEALTH_FIXTURE="$HERE/fixtures/$1" timeout 120 sh "$HERE/test.sh" 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' | awk -v id="$2:" '$2==id {print $1; exit}'
}
expect() {
  local got; got="$(verdict "$1" "$2")"; got="${got:-absent}"; ran=$((ran + 1))
  if [[ "$got" == "$3" ]]; then echo "  ok    $1/$2 -> $got"; else echo "  FAIL  $1/$2 -> $got (expected $3)"; fails=$((fails + 1)); fi
}
for r in ga_manager ga_mosquitto ga_influxdbv1; do
  expect base "HLTH-REQ-$r" PASS
  expect must-pass-addon-prefix "HLTH-REQ-$r" PASS
done
expect must-fail-mosquitto-missing HLTH-REQ-ga_mosquitto FAIL
expect must-fail-mosquitto-missing HLTH-REQ-ga_manager PASS
expect must-fail-influx-missing HLTH-REQ-ga_influxdbv1 FAIL
[[ "$ran" -gt 0 ]] || { echo "FATAL: nothing inspected"; exit 2; }
if [[ "$fails" -eq 0 ]]; then echo "health selftest: $ran/$ran as expected"; else echo "health selftest: $fails of $ran FAILED"; exit 1; fi
