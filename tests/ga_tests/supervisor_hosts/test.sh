#!/bin/sh
# Supervisor name resolution — runs ON the device.
#
# The Supervisor must reach the GA services (OTA store, InfluxDB, Loki, MQTT,
# fleet) by their MESH addresses, the ones ga-services.conf pins. Until
# BOSv1.4.0-rc6 it did not: ga-update-hosts tried to append the entries to the
# container's /etc/hosts through `docker exec`, the upstream AppArmor profile
# hassio-supervisor denied the write, the error was swallowed, and the
# container resolved every GA name through public DNS (measured on a canary
# running rc5, 2026-10-06). That stays invisible until the OTA store is
# reachable over the mesh only — then the Supervisor cannot update anything.
#
# Expected addresses come from the device's OWN ga-services.conf (baked, then
# the /mnt/data override on top, the same layering ga-update-hosts uses) and
# the active OTA pick — never from the hosts file under test, and never from a
# constant in this public repo. The lookup runs inside the container with the
# Supervisor's own Python, i.e. the resolver its HTTP client uses.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Supervisor name resolution (GA mesh pins)"

SUP=hassio_supervisor
MANAGED="${GA_SUPERVISOR_HOSTS_FILE:-/mnt/data/ga-supervisor-hosts}"
OTA_ACTIVE="${GA_OTA_ACTIVE_FILE:-/run/ga-resolve-ota.active}"
BAKED="${GA_SERVICES_CONF_BAKED:-/etc/ga-services.conf}"
OVERRIDE="${GA_SERVICES_CONF_OVERRIDE:-/mnt/data/ga-services.conf}"

# The device's own configuration, layered like ga-update-hosts reads it.
# (The path overrides exist only to dry-run this suite off-device.)
CONF=$(
  [ -f "$BAKED" ] && . "$BAKED"
  [ -f "$OVERRIDE" ] && . "$OVERRIDE"
  echo "SVC_IP='${GA_SERVICES_IP:-}'"
  echo "OTA_HOST='${GA_OTA_HOST:-}'"
  echo "OTA_IPS='${GA_OTA_IPS:-}'"
  echo "NAMES='${GA_INFLUX_HOST:-} ${GA_LOKI_HOST:-} ${GA_MQTT_HOST:-} ${GA_FLEET_HOST:-}'"
)
eval "$CONF"

OTA_IP=""
[ -f "$OTA_ACTIVE" ] && OTA_IP=$(tr -d '[:space:]' < "$OTA_ACTIVE")
[ -z "$OTA_IP" ] && OTA_IP=$(echo "$OTA_IPS" | awk '{print $1}')

run_test "SUPH-01" "device configuration names the services address and the OTA host" \
  '[ -n "$SVC_IP" ] && [ -n "$OTA_HOST" ] && [ -n "$OTA_IP" ]'

run_test_ready "SUPH-02" "$SUP container running" \
  "docker inspect -f '{{.State.Running}}' $SUP 2>/dev/null | grep -qx true" 300 \
  "docker inspect -f '{{.State.Running}}' $SUP 2>/dev/null | grep -qx true"

run_test_show "SUPH-03" "/etc/hosts in $SUP is the host-managed file, mounted read-only" \
  "m=\$(docker inspect -f '{{range .Mounts}}{{if eq .Destination \"/etc/hosts\"}}{{.Source}} rw={{.RW}}{{end}}{{end}}' $SUP 2>/dev/null); echo \"\${m:-no mount at /etc/hosts}\"; [ \"\$m\" = \"$MANAGED rw=false\" ]"

# resolve <name> — the address the Supervisor's Python gets for <name>.
resolve() {
  docker exec "$SUP" python3 -c \
    'import socket, sys; print(socket.gethostbyname(sys.argv[1]))' "$1" 2>&1
}

N=0
for _name in $NAMES; do
  N=$((N + 1))
  run_test_show "SUPH-1$N" "$SUP resolves $_name to the configured services address" \
    "got=\$(resolve '$_name'); echo \"got \$got, expected $SVC_IP\"; [ \"\$got\" = '$SVC_IP' ]"
done
if [ -n "$OTA_HOST" ]; then
  N=$((N + 1))
  run_test_show "SUPH-20" "$SUP resolves $OTA_HOST to the active OTA pick" \
    "got=\$(resolve '$OTA_HOST'); echo \"got \$got, expected $OTA_IP\"; [ \"\$got\" = '$OTA_IP' ]"
  run_test "SUPH-21" "the active OTA pick is one of the configured OTA addresses" \
    'echo " $OTA_IPS " | grep -qF " $OTA_IP "'
fi
# Coverage, not exit code: zero names checked is a failure.
run_test "SUPH-22" "at least 5 GA names checked (got $N)" '[ "$N" -ge 5 ]'

run_test_show "SUPH-30" "ga-update-hosts.service did not fail" \
  "s=\$(systemctl show ga-update-hosts.service -p Result --value 2>/dev/null); echo \"Result=\$s\"; [ \"\$s\" = success ]"
run_test_ready "SUPH-31" "ga-supervisor-hosts-check.service ran and succeeded" \
  "systemctl show ga-supervisor-hosts-check.service -p ActiveState --value 2>/dev/null | grep -qvx -e activating -e active" 360 \
  "[ \"\$(systemctl show ga-supervisor-hosts-check.service -p Result --value 2>/dev/null)\" = success ] && [ \"\$(systemctl show ga-supervisor-hosts-check.service -p ExecMainStartTimestampMonotonic --value 2>/dev/null)\" != 0 ]"

suite_end
