#!/bin/sh
# selftest.sh — drive site_config_verdict.sh (HCA-09/10/11) over fixtures.
# Host-side, sh + jq. Runs in CI (lint.yml host-suites); needs no device.
#
# The Core fixtures are the shape Home Assistant 2026.8.2 answers on
# /api/config (core_config.py Config.as_dict, unit_system as the per-measurement
# dict from util/unit_system.py). The script under test is the LIVE file next to
# this one, never a copy. Every check has must-pass AND must-fail cases.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
V="$HERE/site_config_verdict.sh"
FX="$HERE/fixtures"

[ -f "$V" ] || { echo "FAIL: $V not found — refusing to report a pass over nothing"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required"; exit 1; }

n=0; bad=0
expect() {  # <cfg> <core> <key|source> <PASS|FAIL|SKIP>
  _cfg="$1"; _core="$2"; _k="$3"; _want="$4"
  n=$((n+1))
  if [ "$_k" = source ]; then
    _out=$(sh "$V" source "$FX/core/$_core.json" 2>&1); _rc=$?
  else
    _out=$(sh "$V" "$_k" "$FX/$_cfg.yaml" "$FX/core/$_core.json" 2>&1); _rc=$?
  fi
  case "$_rc" in 0) _got=PASS ;; 2) _got=SKIP ;; *) _got=FAIL ;; esac
  if [ "$_got" = "$_want" ]; then
    printf '  ok    %-22s %-19s %-11s %s  (%s)\n' "$_cfg" "$_core" "$_k" "$_got" "$_out"
  else
    printf '  WRONG %-22s %-19s %-11s got %s, want %s  (%s)\n' "$_cfg" "$_core" "$_k" "$_got" "$_want" "$_out"
    bad=$((bad+1))
  fi
}

value() {  # <cfg> <key> <expected>
  n=$((n+1))
  _got=$(sh "$V" value "$2" "$FX/$1.yaml")
  if [ "$_got" = "$3" ]; then
    printf '  ok    value %-16s %-12s = %s\n' "$1" "$2" "$_got"
  else
    printf '  WRONG value %-16s %-12s = [%s], want [%s]\n' "$1" "$2" "$_got" "$3"
    bad=$((bad+1))
  fi
}

OWNED="latitude longitude elevation time_zone country unit_system"

echo "=== site_config_verdict selftest ==="

# must-pass: Core runs every value in the file — whichever writer came last.
# storage-matching is the state after a correct live update through
# config/core/update (ga_manager >= 0.216.0): the old HCA-11 FAILED it.
for k in $OWNED; do expect configuration yaml-matching    "$k" PASS; done
for k in $OWNED; do expect configuration storage-matching "$k" PASS; done
expect configuration elevation-float elevation PASS   # 34 in the file, 34.0 from Core: same value

# HCA-11 is information: it never fails, whatever Core says or cannot say
for c in yaml-matching storage-matching moved-latitude empty garbage unauthorized; do
  expect - "$c" source PASS
done

# must-fail: Core runs something else than the file says
expect configuration moved-latitude     latitude  FAIL
expect configuration moved-latitude     longitude PASS   # one fault reads as one
expect configuration latitude-lookalike latitude  FAIL   # the old prefix grep passed this
expect configuration us-units           unit_system FAIL
expect configuration us-units           latitude  PASS
expect configuration wrong-tz-country   time_zone FAIL
expect configuration wrong-tz-country   country   FAIL

# could not ask Core — a FAIL, never a pass and never a skip
for c in empty garbage unauthorized; do
  for k in latitude time_zone unit_system; do expect configuration "$c" "$k" FAIL; done
done

# nothing to compare: the key is not in the file
expect configuration-partial storage-matching elevation SKIP
for k in latitude longitude time_zone country unit_system; do
  expect configuration-partial storage-matching "$k" PASS
done
expect configuration storage-matching currency FAIL   # not an owned key: refused, not guessed

# extraction: the homeassistant: block only, quotes and trailing comments off,
# colons inside a value kept (the greedy-sed bug of 2026-08-26)
value configuration         internal_url "http://kibu.local"
value configuration         latitude     52.520008
value configuration-partial latitude     52.520008
value configuration-partial country      DE
value configuration-partial time_zone    Europe/Berlin
value configuration-partial elevation    ""
value configuration-partial internal_url "http://kibu.local:8123"

echo "--- $n cases, $bad wrong ---"
[ "$n" -ge 49 ] || { echo "FAIL: only $n cases ran — the table is broken"; exit 1; }
[ "$bad" -eq 0 ]
