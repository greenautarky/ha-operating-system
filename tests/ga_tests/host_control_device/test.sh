#!/bin/sh
# host_control_device — on a booted device from BOSv1.4.0-rc3 on, the host
# takes control requests from ga_manager only out of the add-on's own data
# directory under its pinned slug (ADR-0041), and ga_manager actually writes
# them there. The host-side fixtures (tests/ga_tests/host_control, CI) prove the
# scripts; this suite proves the seam on the real device: the pinned slug is
# the one installed, the host told ga_manager its release, and nothing is left
# waiting in /share where this host no longer looks.
#
# Every check gates on the device paths, so a host run degrades to SKIP.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "host control via ga_manager's data directory (ADR-0041)"

GM=/mnt/data/supervisor/addons/data/99f1cad4_ga_manager
SHARE=/mnt/data/supervisor/share
ADDONS=/mnt/data/supervisor/addons/data

if [ ! -d "$ADDONS" ] || [ ! -r /etc/ga-release ]; then
  skip_test "HCD-01" "ga_manager data dir under the pinned slug" "not a GA device (host run)"
  suite_end; exit 0
fi

# Does this image read control requests from ga_manager's data dir at all?
if ! grep -q "PathChanged=$GM/ga-rauc-install-request" /usr/lib/systemd/system/ga-rauc-install.path 2>/dev/null; then
  skip_test "HCD-01" "host control via ga_manager's data dir" "this image predates ADR-0041 ($(cat /etc/ga-release))"
  suite_end; exit 0
fi

# HCD-01: the directory the host reads is the one ga_manager actually has. A
# ga_manager installed under another repository slug writes somewhere this
# host never looks — every control request would be dead.
others=$(ls -d "$ADDONS"/*_ga_manager 2>/dev/null | grep -v "^$GM\$" | tr '\n' ' ')
run_test "HCD-01" "ga_manager's data dir exists under the pinned slug 99f1cad4_ga_manager" \
  "[ -d '$GM' ] && [ ! -L '$GM' ]"
[ -z "$others" ] || printf '        other ga_manager data dirs present: %s\n' "$others"

# HCD-02: the host told ga_manager which release it runs (ga-gm-host-release).
run_test "HCD-02" "ga-host-release in ga_manager's data dir equals /etc/ga-release" \
  "[ -f '$GM/ga-host-release' ] && [ ! -L '$GM/ga-host-release' ] && [ \"\$(cat '$GM/ga-host-release')\" = \"\$(cat /etc/ga-release)\" ]"

# HCD-03: the OS-install watcher is armed on the pinned path.
run_test "HCD-03" "ga-rauc-install.path is active" "systemctl is-active --quiet ga-rauc-install.path"

# HCD-04: nothing waits in /share where this host no longer looks. A request
# file there means a ga_manager older than ADR-0041 tried to update this host
# and the update silently did not happen.
run_test "HCD-04" "no OS install request is waiting in /share (it would never be acted on)" \
  "[ ! -e '$SHARE/ga-rauc-install-request' ] && [ ! -e '$SHARE/ga-rauc-install-request.rc' ]"

# HCD-05: Bluetooth — the gate applied what ga_manager asked for in its data
# dir (or the manual boot marker). Changed since boot -> a reboot is pending,
# which ga_manager's ga.bluetooth check reports; judge only a settled device.
want=off
{ [ -f "$GM/ga-bluetooth-enabled" ] && [ ! -L "$GM/ga-bluetooth-enabled" ]; } && want=on
[ -e /mnt/boot/ga-bluetooth ] && want=on
have=off; [ -e /run/ga-bluetooth.enabled ] && have=on
if [ "$want" = on ] && [ -f "$GM/ga-bluetooth-enabled" ] && [ "$GM/ga-bluetooth-enabled" -nt /run/ga-bluetooth.enabled ] 2>/dev/null; then
  skip_test "HCD-05" "Bluetooth applied as requested" "the flag changed since boot — reboot pending"
else
  run_test "HCD-05" "Bluetooth applied as requested in ga_manager's data dir (want=$want have=$have)" "[ '$want' = '$have' ]"
fi
warn_test "HCD-05b" "no Bluetooth flag left in /share (this host ignores it; one there means a ga_manager older than ADR-0041)" \
  "[ ! -e '$SHARE/ga-bluetooth-enabled' ]"

# HCD-06: LTE standby verdict — ga_manager publishes where this host reads.
if [ -e "$GM/ga-lte-standby.json" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$GM/ga-lte-standby.json" 2>/dev/null || echo 0) ))
  run_test "HCD-06" "the LTE standby verdict in ga_manager's data dir is fresh (${age}s, limit 600s)" "[ $age -le 600 ]"
elif [ -e "$SHARE/ga-lte-standby.json" ]; then
  run_test "HCD-06" "the LTE standby verdict is published where this host reads it" "false"
  printf '        %s exists, %s does not — the standby route is unmanaged on this host\n' "$SHARE/ga-lte-standby.json" "$GM/ga-lte-standby.json"
else
  skip_test "HCD-06" "LTE standby verdict" "no standby hop declared on this device"
fi

# HCD-07: Ethernet — once ga_manager has converged, its marker is in its data
# dir (the retire trigger). ETHF-06 judges the retire outcome itself.
if [ -e "$SHARE/.ga_converged" ]; then
  run_test "HCD-07" "a converged device carries the converged marker in ga_manager's data dir" \
    "[ -f '$GM/.ga_converged' ] && [ ! -L '$GM/.ga_converged' ]"
else
  skip_test "HCD-07" "converged marker in ga_manager's data dir" "device has not converged yet"
fi

suite_end
