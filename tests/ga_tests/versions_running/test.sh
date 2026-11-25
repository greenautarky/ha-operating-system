#!/bin/sh
# Versions Running - does the device RUN what the image pins? (Core, Supervisor, every pinned add-on)
#
# os_integrity OSI-10.. proves that a pinned image is PRESENT. A fresh device installs the STORE
# version, so a pin ahead of the store is baked and never runs (2026-11-24: influx 0.0.23 ran with 0.0.25
# baked). A store_ahead pin therefore fails here unless the device was seeded from the bench store.
# Run on a PROVISIONED device. Expectations: generated constants, one file per board.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
suite_start "Versions Running (running == pinned)"
case "${VR_FORCE_BOARD:-$(uname -m)}" in
  armv7l|ihost) _b=ihost ;;
  aarch64|dsgw210) _b=dsgw210 ;;
  *) _b=unknown ;;
esac
EXP="$SCRIPT_DIR/expected.$_b.env"
if [ ! -s "$EXP" ]; then
  run_test "VRUN-00" "expectations for board '$_b' present" "false"
  suite_end; exit 1
fi
. "$EXP"
run_test "VRUN-00" "expectations complete ($_b)" '[ -n "$VR_CORE" ] && [ -n "$VR_SUPERVISOR" ] && [ "$(echo "$VR_ADDONS" | wc -w)" -ge 5 ]'
[ -z "$VR_STORE_AHEAD" ] || echo "  store_ahead pins: $VR_STORE_AHEAD - they run only on a device seeded from the bench store"

vr_image() { docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null; }
# every container (running or not) made from this repository, as "name image"
vr_of() { docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null | while read -r _n _i; do [ "${_i%:*}" = "$1" ] && echo "$_n"; done; }

wait_for "${VR_WAIT:-900}" 'docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^homeassistant$" && [ "$(docker ps --format "{{.Names}}" | grep -cE "^(app|addon)_")" -ge 5 ]' || # ga-ctr-ok
  echo "  (readiness timed out - judging the current state)"
run_test_show "VRUN-01" "Core runs $VR_CORE" '[ "$(vr_image homeassistant | sed "s/.*://")" = "$VR_CORE" ]'
run_test_show "VRUN-02" "Supervisor runs $VR_SUPERVISOR" '[ "$(docker inspect -f "{{index .Config.Labels \"io.hass.version\"}}" hassio_supervisor 2>/dev/null)" = "$VR_SUPERVISOR" ]'
_i=10
for _p in $VR_ADDONS; do
  _k="${_p%%=*}"; _r="${_p#*=}"; _repo="${_r%:*}"; _v="${_r##*:}"
  _c="$(vr_of "$_repo" | head -n 1)"; _run="$([ -n "$_c" ] && vr_image "$_c" | sed 's/.*://')"
  if [ -z "$_c" ] && [ "$_k" = sonoff_dongle_flasher ]; then
    # install-only: the Supervisor removes its container when it is stopped; its version is then in the store data
    _sv="$(jq -r --arg s _sonoff_dongle_flasher_for_ihost '.user | to_entries[] | select(.key|endswith($s)) | .value.version' "${VR_APPS_JSON:-/mnt/data/supervisor/apps.json}" 2>/dev/null | head -n 1)"
    _run="$_sv"
  fi
  run_test_show "VRUN-$_i" "$_k runs the pinned $_v (is: ${_run:-nothing})" '[ "$_run" = "$_v" ] && [ "$(vr_of "$_repo" | wc -l)" -le 1 ]'
  _i=$((_i+1))
done
run_test "VRUN-90" "every pinned add-on was judged" '[ "$((_i-10))" = "$(echo "$VR_ADDONS" | wc -w)" ]'
suite_end
