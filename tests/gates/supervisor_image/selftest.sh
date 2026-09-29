#!/usr/bin/env bash
# Runs the LIVE buildroot-external/package/hassio/check-supervisor-image.sh
# against every fixture: must-fail/* must exit non-zero, must-pass/* must exit 0.
# Each fixture dir holds version.json, config.json (an image config as
# `skopeo inspect --config` prints it, trimmed to architecture + labels +
# entrypoint) and pin (the version.yaml homeassistant_supervisor value).
# must-pass/ga-2025.11.5.4 is the real config of the GA image, read from the
# registry on 2026-09-28. Zero fixtures inspected = FAIL.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
gate="$here/../../../buildroot-external/package/hassio/check-supervisor-image.sh"
[ -x "$gate" ] || { echo "FAIL: gate not found: $gate"; exit 1; }
n=0 np=0 bad=0
for d in "$here"/must-fail/*/ "$here"/must-pass/*/; do
  [ -f "$d/version.json" ] || continue
  n=$((n+1)); kind="$(basename "$(dirname "$d")")"; name="$(basename "$d")"
  [ "$kind" = must-pass ] && np=$((np+1))
  out="$(SUPERVISOR_IMAGE_CONFIG_FILE="$d/config.json" "$gate" "$d/version.json" armv7 "$(cat "$d/pin")" 2>&1)"; rc=$?
  if { [ "$kind" = must-fail ] && [ "$rc" -ne 0 ]; } || { [ "$kind" = must-pass ] && [ "$rc" -eq 0 ]; }; then
    echo "  ok    $kind/$name (rc=$rc) ${out%%$'\n'*}"
  else
    echo "  FAIL  $kind/$name (rc=$rc) ${out%%$'\n'*}"; bad=1
  fi
done
[ "$n" -ge 8 ] && [ "$np" -ge 1 ] || { echo "FAIL: only $n fixtures ($np must-pass) inspected"; exit 1; }
echo "$n fixtures inspected"
exit "$bad"
