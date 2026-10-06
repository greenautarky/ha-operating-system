#!/bin/sh
# hassos-supervisor asks the device's OWN channel file, not always stable.json.
#
# hassos-supervisor re-pulls the Supervisor when its image is missing. With no
# local version it used to ask a literal .../main/stable.json, whatever channel
# the device follows, so a dev or beta device came back with the STABLE
# Supervisor. The channel lives in /mnt/data/supervisor/updater.json, seeded by
# the bake (dind-import-containers.sh) and kept by the Supervisor.
#
# Host-side, needs sh + jq. Sources the LIVE script (on a device: the installed
# one; in the repo: the overlay copy) with HASSOS_SUPERVISOR_FUNCTIONS_ONLY=1,
# which returns after the two helper functions and before anything touches the
# host. Red-proven against the script before this change: HSC-01..08 fail
# (the functions do not exist) and HSC-09 fails (the stable.json literal).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "hassos-supervisor channel"

LAUNCH="${HASSOS_SUPERVISOR:-/usr/sbin/hassos-supervisor}"
[ -f "$LAUNCH" ] || LAUNCH="$SCRIPT_DIR/../../../buildroot-external/rootfs-overlay/usr/sbin/hassos-supervisor"

if ! command -v jq >/dev/null 2>&1; then
  skip_test "HSC-01..09" "channel derivation" "jq not available"
  suite_end
  exit $?
fi

W="$(mktemp -d 2>/dev/null || echo "/tmp/hsc_$$")"
mkdir -p "$W"
trap 'rm -rf "$W"' EXIT INT TERM
printf '{"channel":"dev","homeassistant":"2026.8.2.1"}' > "$W/dev.json"
printf '{"channel":"beta"}' > "$W/beta.json"
printf '{"channel":"stable"}' > "$W/stable.json"
printf '{"homeassistant":"2026.8.2.1"}' > "$W/nochannel.json"
printf '{"channel":"../../evil"}' > "$W/garbage.json"
printf '{not json' > "$W/broken.json"

# Each call sources the live script in a subshell and prints the URL it
# derives; stderr is kept apart so the loud fallback can be asserted too.
# NEVER source a launcher without the functions-only hook: an older one would
# run for real — as root on a device it recreates and starts the Supervisor.
HOOKED=0
grep -q 'HASSOS_SUPERVISOR_FUNCTIONS_ONLY' "$LAUNCH" 2>/dev/null && HOOKED=1
url_for() {
  [ "$HOOKED" = 1 ] || { echo "launcher has no functions-only hook - not sourced" > "$W/err"; return 1; }
  ( HASSOS_SUPERVISOR_FUNCTIONS_ONLY=1; . "$LAUNCH"; ga_channel_version_url "$1" ) 2>"$W/err"
}
BASE="https://raw.githubusercontent.com/greenautarky/haos-version/main/"

run_test "HSC-01" "dev device asks dev.json" \
  '[ "$(url_for "$W/dev.json")" = "${BASE}dev.json" ]'
run_test "HSC-02" "beta device asks beta.json" \
  '[ "$(url_for "$W/beta.json")" = "${BASE}beta.json" ]'
run_test "HSC-03" "stable device asks stable.json" \
  '[ "$(url_for "$W/stable.json")" = "${BASE}stable.json" ]'
run_test "HSC-04" "updater.json without a channel -> stable (the Supervisor default)" \
  '[ "$(url_for "$W/nochannel.json")" = "${BASE}stable.json" ]'
run_test "HSC-05" "unknown channel value -> stable, never interpolated into the URL" \
  '[ "$(url_for "$W/garbage.json")" = "${BASE}stable.json" ]'
run_test "HSC-06" "unknown channel value -> warning on stderr (loud fallback)" \
  'url_for "$W/garbage.json" >/dev/null; grep -q "WARNING" "$W/err"'
run_test "HSC-07" "unparseable updater.json -> stable + warning" \
  '[ "$(url_for "$W/broken.json")" = "${BASE}stable.json" ] && grep -q "WARNING" "$W/err"'
run_test "HSC-08" "missing updater.json -> stable + warning" \
  '[ "$(url_for "$W/absent.json")" = "${BASE}stable.json" ] && grep -q "WARNING" "$W/err"'
# Static: the literal that caused the defect must not come back.
run_test "HSC-09" "no hardcoded .../stable.json URL left in the launch script" \
  '! grep -q "haos-version/[^\"]*/stable\.json" "$LAUNCH"'

suite_end
