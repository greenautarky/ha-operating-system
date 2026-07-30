#!/bin/sh
# Ethernet force-marker: the shipping gate.
#
# Provisioning runs over Ethernet via /mnt/boot/ga-ethernet-force. Since #298 the
# IMAGE BUILD writes it (board hassos-hook.sh), so every freshly flashed card
# carries it — an earlier version of this comment said it came from
# `verify-sd.sh --flash --ethernet-force`, which is now only the way to re-add it
# after an OTA has dropped it.
#
# That change is why this suite matters more than it did when it was written.
# While the marker arrived at flash time, its presence at least meant somebody
# had handled the card. Now it means nothing but "factory image", so the ONLY
# thing standing between a customer and a network interface they never agreed to
# is the provisioner's removal step — and this suite checking it.
#
# THIS SUITE IS THE EXIT TEST. Run it on the device after the provisioner has
# removed the marker and before the unit is packed. It fails while the marker is
# still there, on purpose — "the provisioner removes it" is a step that can be
# forgotten, and nothing else in the system notices.
#
# Runs ON the device.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Ethernet force-marker (shipping gate)"

FORCE_BOOT=/mnt/boot/ga-ethernet-force
STATUS=/mnt/data/supervisor/share/ga-ethernet-status.json

# --- the marker itself -------------------------------------------------------
if [ -e "$FORCE_BOOT" ]; then
    run_test "ETHF-01" "provisioning marker removed before shipping" "false"
    printf '        %s still exists. Contents:\n' "$FORCE_BOOT"
    sed 's/^/          /' "$FORCE_BOOT" 2>/dev/null | head -4
    printf '        Remove it and reboot:  rm -f %s && reboot\n' "$FORCE_BOOT"
else
    run_test "ETHF-01" "provisioning marker removed before shipping" "true"
fi

# --- what the OS actually DID ------------------------------------------------
# Two separate claims. The file being gone is intent; the status file is the
# effect. A device can have the marker removed and still be running with the
# interface forced up until it reboots — that is the case this catches.
if [ -f "$STATUS" ]; then
    run_test "ETHF-02" "OS published an ethernet status" "true"
    SRC=$(sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATUS" | head -1)
    EN=$(sed -n 's/.*"enabled"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p' "$STATUS" | head -1)
    printf '        source=%s enabled=%s\n' "${SRC:-?}" "${EN:-?}"
    case "$SRC" in
        force-boot)
            run_test "ETHF-03" "effective state is not the flash-time override" "false"
            printf '        The running system still has eth0 forced up by the boot marker.\n'
            printf '        Removing the file is not enough until the device reboots.\n'
            ;;
        "")
            run_test "ETHF-03" "effective state is not the flash-time override" "false"
            printf '        status file carries no "source" — cannot tell who decided.\n'
            ;;
        *)  run_test "ETHF-03" "effective state is not the flash-time override" "true" ;;
    esac
else
    # Not a pass. An absent status file means the OS side never ran, and then
    # nothing here knows what the interface is doing.
    run_test "ETHF-02" "OS published an ethernet status" "false"
    printf '        %s missing — ga-manage-ethernet never reported. This is NOT\n' "$STATUS"
    printf '        evidence that ethernet is off; it is evidence of not knowing.\n'
    skip_test "ETHF-03" "effective state — no status file to read"
fi

# --- the link, as the kernel sees it ----------------------------------------
# Last resort, independent of both files above.
OPER=$(cat /sys/class/net/eth0/operstate 2>/dev/null)
if [ -n "$OPER" ]; then
    printf '        eth0 operstate=%s\n' "$OPER"
    if grep -q '^GA_ETHERNET_ENABLED=true' /mnt/data/ga-env.conf 2>/dev/null; then
        skip_test "ETHF-04" "link state — consent is granted, up is correct"
    else
        run_test "ETHF-04" "eth0 down while consent is absent" "[ \"$OPER\" = down ]"
    fi
else
    skip_test "ETHF-04" "link state — no eth0 on this device"
fi

suite_end
