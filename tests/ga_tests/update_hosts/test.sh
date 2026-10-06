#!/bin/sh
# ga-update-hosts — the Supervisor container must resolve the GA names to the
# mesh addresses, and a failure to get there must be LOUD.
#
# WHY THIS EXISTS. ga-update-hosts appended the GA entries to the Supervisor
# container's /etc/hosts through `docker exec`. The upstream AppArmor profile
# hassio-supervisor denies that write. The error went to /dev/null behind
# `|| true` and the script still logged "injected entries". Measured on a
# canary running BOSv1.4.0-rc5 (2026-10-06): six apparmor="DENIED" lines on
# /etc/hosts, zero GA entries in the container; names the DNS plugin does
# not carry (mqtt, fleet) resolved elsewhere or not at all. Now hassos-supervisor mounts a host-managed file read-only at
# /etc/hosts and ga-update-hosts writes it and verifies from inside.
#
# Host-side: needs sh + awk + stat. Runs the LIVE ga-update-hosts (override
# with GA_UPDATE_HOSTS=<path>) against a fake Docker CLI that models the
# measured container (fake-docker: AppArmor denies /etc/hosts writes, no entry
# = public DNS answer, a bind mount = the host file). Also sources the live
# hassos-supervisor launcher functions-only for the mount helper.
# Fixture addresses are RFC 5737 documentation space.
#
# Red-proven against the script and launcher before this change (the script's
# paths made overridable, nothing else): 20 of 23 fail, among them UH-01 (the
# old script exits 0 and logs "injected" while the container has no entry).
# UH-06, UH-13 and UH-20 pass there by construction (nothing written, nothing
# mounted).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "ga-update-hosts (Supervisor name resolution)"

REPO="$SCRIPT_DIR/../../.."
UH="${GA_UPDATE_HOSTS:-$REPO/buildroot-ihost/rootfs-overlay/usr/sbin/ga-update-hosts}"
LAUNCH="${HASSOS_SUPERVISOR:-$REPO/buildroot-external/rootfs-overlay/usr/sbin/hassos-supervisor}"

W="$(mktemp -d 2>/dev/null || echo "/tmp/uh_$$")"
mkdir -p "$W/bin" "$W/state"
trap 'rm -rf "$W"' EXIT INT TERM
cp "$SCRIPT_DIR/fake-docker" "$W/bin/docker"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/systemctl"
printf '#!/bin/sh\nexit 2\n' > "$W/bin/getent"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/sleep"
chmod +x "$W/bin/docker" "$W/bin/systemctl" "$W/bin/getent" "$W/bin/sleep"

cat > "$W/baked.conf" <<'CONF'
GA_OTA_HOST=ota.example.invalid
GA_OTA_IPS="192.0.2.21 192.0.2.22"
GA_SERVICES_IP=192.0.2.10
GA_INFLUX_HOST=influx.example.invalid
GA_LOKI_HOST=loki.example.invalid
GA_MQTT_HOST=mqtt.example.invalid
GA_FLEET_HOST=fleet.example.invalid
CONF
SUPF="$W/ga-supervisor-hosts"
ST="$W/state"
printf '127.0.0.1\tlocalhost\n172.30.32.2\tdeadbeef\n' > "$ST/own_hosts"

# container <running:true|false|none> <mount: yes|no>
container() {
  rm -f "$ST/running" "$ST/mount_src"
  [ "$1" = none ] || echo "$1" > "$ST/running"
  [ "$2" = yes ] && echo "$SUPF" > "$ST/mount_src"
  : > "$ST/log"
}

# run_uh [args] — the live script, all paths in the sandbox, output in $W/out.
run_uh() {
  PATH="$W/bin:$PATH" \
  FAKE_DOCKER_STATE="$ST" \
  GA_SERVICES_CONF_BAKED="$W/baked.conf" \
  GA_SERVICES_CONF_OVERRIDE="$W/absent.conf" \
  GA_HOSTS_FILE="$W/hosts" \
  GA_OTA_ACTIVE_FILE="$W/ota.active" \
  GA_APPLIED_IP_FILE="$W/applied-ip" \
  GA_SUPERVISOR_HOSTS_FILE="$SUPF" \
  GA_SUPERVISOR_WAIT_S=0 \
  sh "$UH" "$@" > "$W/out" 2>&1
}

# --- the measured defect: container without the mount, AppArmor denies -------
container true no
run_uh; RC=$?
run_test "UH-01" "Supervisor cannot get the GA entries -> exit non-zero (was: exit 0)" \
  '[ "$RC" -ne 0 ]'
run_test "UH-02" "... and says so at error level, naming the missing entry" \
  'grep -q "ERROR" "$W/out" && grep -q "no .192.0.2.10 influx.example.invalid. entry" "$W/out"'
run_test "UH-03" "never claims entries were injected while the container lacks them" \
  '! grep -qi "injected" "$W/out"'

# --- fixed path: container mounts the host-managed file -----------------------
rm -f "$SUPF"
container true yes
: > "$SUPF"
INODE_BEFORE=$(stat -c %i "$SUPF")
run_uh; RC=$?
run_test "UH-04" "container mounts the managed file -> exit 0, verified from inside" \
  '[ "$RC" -eq 0 ] && grep -q "verified hassio_supervisor — 5 GA names" "$W/out"'
run_test "UH-05" "managed file carries the services line and the OTA line" \
  'grep -qx "192.0.2.10 influx.example.invalid loki.example.invalid mqtt.example.invalid fleet.example.invalid" "$SUPF" && grep -qx "192.0.2.21 ota.example.invalid" "$SUPF"'
run_test "UH-06" "rewritten in place (same inode — a file bind mount pins it)" \
  '[ "$(stat -c %i "$SUPF")" = "$INODE_BEFORE" ]'
run_test "UH-07" "managed file keeps localhost" \
  'grep -q "^127.0.0.1[[:space:]]*localhost" "$SUPF"'

# --- OTA failover reaches the running container without a restart -------------
echo 192.0.2.22 > "$W/ota.active"
run_uh; RC=$?
run_test "UH-08" "OTA failover: container resolves the new OTA address, exit 0" \
  '[ "$RC" -eq 0 ] && grep -qx "192.0.2.22 ota.example.invalid" "$SUPF" && ! grep -q "192.0.2.21" "$SUPF"'
rm -f "$W/ota.active"

# --- container not running yet (boot): write, defer, do not fail --------------
container false yes
run_uh; RC=$?
run_test "UH-09" "container not running -> file written, verification deferred to the check unit, exit 0" \
  '[ "$RC" -eq 0 ] && grep -q "deferred to ga-supervisor-hosts-check" "$W/out" && grep -q "influx.example.invalid" "$SUPF"'

# --- --verify-supervisor (ga-supervisor-hosts-check.service) ------------------
container false yes
run_uh --verify-supervisor; RC=$?
run_test "UH-10" "--verify-supervisor: container never runs -> exit non-zero + ERROR" \
  '[ "$RC" -ne 0 ] && grep -q "ERROR" "$W/out"'
container true yes
run_uh --verify-supervisor; RC=$?
run_test "UH-11" "--verify-supervisor: mounted + resolving -> exit 0" \
  '[ "$RC" -eq 0 ] && grep -q "verified" "$W/out"'
printf '127.0.0.1\tlocalhost\n' > "$SUPF"
run_uh --verify-supervisor; RC=$?
run_test "UH-12" "--verify-supervisor: mounted but entries missing -> exit non-zero, names resolve elsewhere" \
  '[ "$RC" -ne 0 ] && grep -q "resolves to .198.51.100.99." "$W/out"'
run_test "UH-13" "--verify-supervisor writes nothing" \
  '[ "$(cat "$SUPF")" = "$(printf "127.0.0.1\tlocalhost")" ]'
container true no
run_uh --verify-supervisor; RC=$?
run_test "UH-14" "--verify-supervisor: container created without the mount -> exit non-zero, says how to fix" \
  '[ "$RC" -ne 0 ] && grep -q "does not mount" "$W/out" && grep -q "hassos-supervisor.service" "$W/out"'

# --- refuses to write through a symlink -----------------------------------------
rm -f "$SUPF"; echo "untouched" > "$W/elsewhere"; ln -s "$W/elsewhere" "$SUPF"
container true yes
run_uh; RC=$?
run_test "UH-15" "managed path is a symlink -> refuses, exit non-zero, target untouched" \
  '[ "$RC" -ne 0 ] && [ "$(cat "$W/elsewhere")" = untouched ]'
rm -f "$SUPF"

# --- static: the denied write path must not come back ---------------------------
run_test "UH-16" "no docker exec writes /etc/hosts inside a container (code, not comments)" \
  '! grep -vE "^[[:space:]]*#" "$UH" | grep -A2 "docker exec" | grep -qE ">>? */etc/hosts"'
run_test "UH-17" "no docker exec result is swallowed with || true" \
  '! grep -vE "^[[:space:]]*#" "$UH" | grep -A2 "docker exec" | grep -qF "|| true"'

# --- launcher: the mount, and one path in two files -----------------------------
HOOKED=0
grep -q 'HASSOS_SUPERVISOR_FUNCTIONS_ONLY' "$LAUNCH" 2>/dev/null && HOOKED=1
mount_for() {
  [ "$HOOKED" = 1 ] || { echo "launcher has no functions-only hook - not sourced" > "$W/err"; return 1; }
  ( HASSOS_SUPERVISOR_FUNCTIONS_ONLY=1; . "$LAUNCH"; ga_supervisor_hosts_mount "$@" ) 2>"$W/err"
}
WRITER="$W/bin/systemctl"   # any executable stands in for the writer
printf '127.0.0.1\tlocalhost\n' > "$W/present"
run_test "UH-18" "launcher: file present -> read-only bind mount at /etc/hosts" \
  '[ "$(mount_for "$W/present" "$WRITER")" = "-v $W/present:/etc/hosts:ro" ]'
run_test "UH-19" "launcher: file missing -> seeded with localhost, mounted, WARNING" \
  'rm -f "$W/seeded"; [ "$(mount_for "$W/seeded" "$WRITER")" = "-v $W/seeded:/etc/hosts:ro" ] && grep -q "^127.0.0.1" "$W/seeded" && grep -q WARNING "$W/err"'
run_test "UH-20" "launcher: image without ga-update-hosts -> no mount" \
  '[ -z "$(mount_for "$W/present" "$W/no-writer")" ]'
ln -s "$W/present" "$W/link"
run_test "UH-21" "launcher: symlink -> no mount + ERROR" \
  'out="$(mount_for "$W/link" "$WRITER")"; [ -z "$out" ] && grep -q ERROR "$W/err"'
run_test "UH-22" "launcher: mount computed on EVERY launch (before the create block) and passed to create" \
  'awk "/GA_SUPERVISOR_HOSTS_MOUNT=\"\\\$\\(ga_supervisor_hosts_mount\\)\"/{m=NR} /^if \\[ -z \"\\\$\\{SUPERVISOR_CONTAINER_ID\\}\" \\]; then/{c=NR} END{exit !(m && c && m < c)}" "$LAUNCH" && awk "/docker container create/{on=1} on{print} on && /SUPERVISOR_IMAGE\\}:latest\"/{exit}" "$LAUNCH" | grep -qF "\${GA_SUPERVISOR_HOSTS_MOUNT}"'
UH_PATH=$(sed -n 's/^SUP_HOSTS_FILE="\${GA_SUPERVISOR_HOSTS_FILE:-\(.*\)}"$/\1/p' "$UH")
LA_PATH=$(sed -n 's/^ *_ga_sh_src="\${1:-\(.*\)}"$/\1/p' "$LAUNCH")
run_test "UH-23" "ga-update-hosts writes the file the launcher mounts (both read, both non-empty, equal)" \
  '[ -n "$UH_PATH" ] && [ "$UH_PATH" = "$LA_PATH" ]'

suite_end
