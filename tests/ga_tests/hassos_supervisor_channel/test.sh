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
# which returns after the helper functions and before anything touches the
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

# --- /etc/ga-version-url reaches the Supervisor container (read-only) -------
# GA Supervisor >= 2025.11.5.6 reads /etc/ga-version-url inside its container.
# The launcher mounts the host file at the same path, read-only, and ONLY when
# it is a regular file: bind-mounting a missing source makes Docker try to
# create it (a directory, on a read-only /etc), so the container would not be
# created at all. Missing -> no mount, a WARNING, and the Supervisor's own
# fallback (main). Red-proven: HSC-10..14 fail on the launcher before this.
printf 'https://raw.githubusercontent.com/greenautarky/haos-version/candidate/stable-1.4/\n' > "$W/ga-version-url"
mkdir -p "$W/a-directory"
mount_for() {
  [ "$HOOKED" = 1 ] || { echo "launcher has no functions-only hook - not sourced" > "$W/err"; return 1; }
  ( HASSOS_SUPERVISOR_FUNCTIONS_ONLY=1; . "$LAUNCH"; ga_version_url_mount "$@" ) 2>"$W/err"
}
run_test "HSC-10" "file present -> read-only bind mount at /etc/ga-version-url" \
  '[ "$(mount_for "$W/ga-version-url")" = "-v $W/ga-version-url:/etc/ga-version-url:ro" ]'
run_test "HSC-11" "file absent -> no mount and a WARNING (Supervisor falls back to main)" \
  'out="$(mount_for "$W/absent")"; [ -z "$out" ] && grep -q "WARNING" "$W/err"'
run_test "HSC-12" "a directory at the path -> no mount and a WARNING" \
  'out="$(mount_for "$W/a-directory")"; [ -z "$out" ] && grep -q "WARNING" "$W/err"'
# The default path IS /etc/ga-version-url: on a host with the file the
# production mount comes out verbatim; without it the warning names that path.
run_test "HSC-13" "default path is /etc/ga-version-url" \
  'out="$(mount_for)"; [ "$out" = "-v /etc/ga-version-url:/etc/ga-version-url:ro" ] || { [ -z "$out" ] && grep -q "/etc/ga-version-url" "$W/err"; }'
# The create command passes what the function returns.
run_test "HSC-14" "docker container create carries \${GA_VERSION_URL_MOUNT}, set from ga_version_url_mount" \
  'awk "/docker container create/{on=1} on{print} on && /SUPERVISOR_IMAGE\\}:latest\"/{exit}" "$LAUNCH" | grep -qF "\${GA_VERSION_URL_MOUNT}" && grep -qE "^[[:space:]]*GA_VERSION_URL_MOUNT=\"\\\$\\(ga_version_url_mount\\)\"" "$LAUNCH"'

suite_end
