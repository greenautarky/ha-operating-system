#!/usr/bin/env bash
# Runs the LIVE buildroot-external/package/hassio/check-core-image.sh against
# every fixture: must-fail/* must exit non-zero, must-pass/* must exit 0.
# Each fixture dir holds version.json + config.json (an image config as
# `skopeo inspect --config` prints it). Zero fixtures inspected = FAIL.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
gate="$here/../../../buildroot-external/package/hassio/check-core-image.sh"
[ -x "$gate" ] || { echo "FAIL: gate not found: $gate"; exit 1; }
n=0 bad=0
for d in "$here"/must-fail/*/ "$here"/must-pass/*/; do
  [ -f "$d/version.json" ] || continue
  n=$((n+1)); kind="$(basename "$(dirname "$d")")"; name="$(basename "$d")"
  CORE_IMAGE_CONFIG_FILE="$d/config.json" "$gate" "$d/version.json" tinker >/dev/null 2>&1; rc=$?
  if { [ "$kind" = must-fail ] && [ "$rc" -ne 0 ]; } || { [ "$kind" = must-pass ] && [ "$rc" -eq 0 ]; }; then
    echo "  ok    $kind/$name (rc=$rc)"
  else
    echo "  FAIL  $kind/$name (rc=$rc)"; bad=1
  fi
done
[ "$n" -ge 6 ] || { echo "FAIL: only $n fixtures inspected (expected >= 6)"; exit 1; }
echo "$n fixtures inspected"
exit "$bad"
