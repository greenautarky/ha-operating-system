#!/bin/sh
# selftest.sh — drive http_config_verdict.sh (CFG-32a/32/33/34/32b) over fixtures.
# Host-side, sh + jq. Runs in CI (lint.yml host-suites); needs no device.
#
# The fixtures are the shapes Core 2026.8.2's `http/config` command returns
# (homeassistant/components/http/websocket_api.py + config.py), wrapped in the
# websocket result message that http_config_query.py prints. The services
# address is TEST-NET-1 (192.0.2.7).
#
# Every check has must-pass AND must-fail cases (rule: a check that cannot go
# green is as useless as one that cannot go red). The script under test is the
# LIVE file next to this one, never a copy.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
V="$HERE/http_config_verdict.sh"
FX="$HERE/fixtures/http_config"
SVC=192.0.2.7

[ -f "$V" ] || { echo "FAIL: $V not found — refusing to report a pass over nothing"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required"; exit 1; }

n=0; bad=0
expect() {  # <fixture> <check> <PASS|FAIL> — why
  _fx="$1"; _chk="$2"; _want="$3"
  n=$((n+1))
  _out=$(sh "$V" "$_chk" "$FX/$_fx.json" "$SVC" 2>&1) && _got=PASS || _got=FAIL
  if [ "$_got" = "$_want" ]; then
    printf '  ok    %-26s %-9s %s  (%s)\n' "$_fx" "$_chk" "$_got" "$_out"
  else
    printf '  WRONG %-26s %-9s got %s, want %s  (%s)\n' "$_fx" "$_chk" "$_got" "$_want" "$_out"
    bad=$((bad+1))
  fi
}

echo "=== http_config_verdict selftest ==="
# must-pass: a device ga_manager configured and Core promoted
for c in readable xff loopback services settled; do expect trusted-settled "$c" PASS; done
# Core stores networks (127.0.0.1/32); a bare address is the same entry
expect trusted-bare-addresses loopback PASS
expect trusted-bare-addresses services PASS

# must-fail: the measured fresh-flash state (2026-09-28) — YAML ignored,
# store created from defaults, no proxy trusted
expect fresh-flash-no-trust readable PASS
expect fresh-flash-no-trust xff      FAIL
expect fresh-flash-no-trust loopback FAIL
expect fresh-flash-no-trust services FAIL
expect fresh-flash-no-trust settled  PASS   # settled — on the wrong config; 32/33/34 carry it

# configured, restarted, never promoted: runs pending, auto-reverts in 5 min
expect pending-unpromoted xff      PASS    # it IS running the trusted config right now...
expect pending-unpromoted settled  FAIL    # ...for five minutes

# the trial failed: pending kept with an error, stable (untrusted) runs
expect pending-failed-trial xff     FAIL
expect pending-failed-trial settled FAIL

# Core fell back to its built-in default: stable is right but not what runs
expect default-fallback xff      FAIL
expect default-fallback loopback FAIL
expect default-fallback settled  FAIL

# ga_manager could not read the services bridge and trusted the loopback alone
expect loopback-only loopback PASS
expect loopback-only services FAIL

# look-alikes are not the address; a range is not accepted either (ga_manager
# trusts exactly two hosts, never a network)
expect lookalike-addresses loopback FAIL
expect lookalike-addresses services FAIL

# could not ask at all — every check fails, none skips
for c in readable xff loopback services settled; do expect not-asked "$c" FAIL; done
expect unknown-command readable FAIL   # Core < 2026.8 answering the new command
expect empty readable FAIL

echo "--- $n cases, $bad wrong ---"
[ "$n" -ge 30 ] || { echo "FAIL: only $n cases ran — the table is broken"; exit 1; }
[ "$bad" -eq 0 ]
