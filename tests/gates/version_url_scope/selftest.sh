#!/usr/bin/env bash
# Runs the LIVE scripts/check-version-url-scope.sh against every fixture:
# must-fail/* must exit non-zero, must-pass/* must exit 0. Each fixture dir
# holds a hassio.mk and a version.yaml. Zero fixtures inspected = FAIL.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
gate="$here/../../../scripts/check-version-url-scope.sh"
[ -x "$gate" ] || { echo "FAIL: gate not found: $gate"; exit 1; }
n=0 np=0 bad=0
for d in "$here"/must-fail/*/ "$here"/must-pass/*/; do
  [ -f "$d/hassio.mk" ] || continue
  n=$((n+1)); kind="$(basename "$(dirname "$d")")"; name="$(basename "$d")"
  [ "$kind" = must-pass ] && np=$((np+1))
  out="$("$gate" "$d/hassio.mk" "$d/version.yaml" 2>&1)"; rc=$?
  # A must-fail fixture names the reason it must fail for (`expect`, a fixed
  # string). Failing for ANOTHER reason means the rule under test is unproven.
  why_ok=1
  if [ "$kind" = must-fail ]; then
    if [ ! -s "$d/expect" ]; then why_ok=0; out="no expect file — $out"
    elif ! grep -qF -- "$(head -1 "$d/expect")" <<<"$out"; then why_ok=0; out="wrong reason (want: $(head -1 "$d/expect")) — $out"
    fi
  fi
  if { [ "$kind" = must-fail ] && [ "$rc" -ne 0 ] && [ "$why_ok" = 1 ]; } || { [ "$kind" = must-pass ] && [ "$rc" -eq 0 ]; }; then
    echo "  ok    $kind/$name (rc=$rc) ${out%%$'\n'*}"
  else
    echo "  FAIL  $kind/$name (rc=$rc) ${out%%$'\n'*}"; bad=1
  fi
done
[ "$n" -ge 14 ] && [ "$np" -ge 3 ] || { echo "FAIL: only $n fixtures ($np must-pass) inspected"; exit 1; }
echo "$n fixtures inspected"
exit "$bad"
