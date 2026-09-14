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
    if [ -e "$FORCE_BOOT" ]; then
        # My own test double-reported: with the marker present, eth0 being up is
        # the EXPECTED consequence, and ETHF-01/03 above already fail for it with
        # the actionable message. Failing a third time here adds no information
        # and pads the failure count, which is how a run stops being read.
        # Measured on K31 2026-07-30: three reds for one cause.
        skip_test "ETHF-04" "link state — the boot marker is present, ETHF-01/03 already report it"
    elif grep -q '^GA_ETHERNET_ENABLED=true' /mnt/data/ga-env.conf 2>/dev/null; then
        skip_test "ETHF-04" "link state — consent is granted, up is correct"
    elif [ "$SRC" = force-config ]; then
        # The fleet-manager's ethernet.force_enabled is the third legitimate
        # reason for eth0 to be up (ETHF-03 already accepted it as "not the
        # flash-time override"). Failing here reported the remote override
        # as a defect on every device that carries it — K55 2026-09-14.
        skip_test "ETHF-04" "link state — remote override (force-config) is active, up is correct"
    else
        run_test "ETHF-04" "eth0 down while consent is absent" "[ \"$OPER\" = down ]"
    fi
else
    skip_test "ETHF-04" "link state — no eth0 on this device"
fi

# --- the retire mechanism ---------------------------------------------------
# ETHF-01 says whether the file is gone. These two say whether the thing that
# is SUPPOSED to remove it exists and ran — the distinction that mattered:
# until 2026-09-08 the removal was a sentence in three comments and no code, so
# ETHF-01 was red on every device and nobody could tell from the suite whether
# a step had failed or had never existed.
CONVERGED=/mnt/data/supervisor/share/.ga_converged

if systemctl cat ga-ethernet-retire.path >/dev/null 2>&1; then
    run_test "ETHF-05" "retire mechanism is installed in the image" "true"
else
    run_test "ETHF-05" "retire mechanism is installed in the image" "false"
    printf '        ga-ethernet-retire.path is not on this device — this OS build\n'
    printf '        has no automatic removal, so ETHF-01 depends on a human.\n'
fi

# The unit is armed by ConditionPathExists on the marker, so it is legitimately
# inactive once the retire has happened. What is tested here is the OUTCOME:
# converged and still carrying the marker means the trigger did not fire.
if [ -e "$CONVERGED" ]; then
    if [ -e "$FORCE_BOOT" ]; then
        run_test "ETHF-06" "retire fired after convergence" "false"
        printf '        %s exists (device is converged) but %s is still here.\n' "$CONVERGED" "$FORCE_BOOT"
        printf '        Check:  systemctl status ga-ethernet-retire.path ga-ethernet-retire.service\n'
        printf '                journalctl -u ga-ethernet-retire.service --no-pager | tail -20\n'
        printf '        Manual: ga-manage-ethernet retire\n'
    else
        run_test "ETHF-06" "retire fired after convergence" "true"
    fi
else
    skip_test "ETHF-06" "retire outcome — device has not converged yet, nothing should have fired"
fi

# --- the remote override must work WITHOUT the legacy label file --------------
# The gate in ga-manage-ethernet accepts the fleet marker only when it names
# this device. Until 2026-09-14 "this device" was read from the flasher's
# legacy /mnt/data/ga-device-label ONLY — a file nothing in the current
# provisioning path writes (the add-on has no /mnt/data mount). So every fresh
# enrolment / reflash refused the remote override ("no label — refusing") and,
# once #509 retired the flash marker, went dark at the next reboot. Masked for
# weeks because the flash marker was still there on every test device.
# Measured K39 2026-09-09, K55 2026-09-14.
#
# ETHF-07 is the static half: the shipped script carries the fallback.
# ETHF-08 is the live half: the real script, the real marker + identity, the
# legacy file temporarily out of the way, and `status` must still say
# force-config. `status` only reads — no state is changed except the label
# file, which is copied aside and restored by a trap.
MANAGE=/usr/sbin/ga-manage-ethernet
LABEL_FILE=/mnt/data/ga-device-label
IDENTITY=$(ls /mnt/data/supervisor/addons/data/*_ga_manager/ga-identity.json 2>/dev/null | head -1)
REMOTE=$(ls /mnt/data/supervisor/addons/data/*_ga_manager/ga-ethernet-force 2>/dev/null | head -1)

if grep -q 'ga-identity.json' "$MANAGE" 2>/dev/null; then
    run_test "ETHF-07" "ga-manage-ethernet derives the label from ga-identity.json" "true"
else
    run_test "ETHF-07" "ga-manage-ethernet derives the label from ga-identity.json" "false"
    printf '        %s reads only %s. A device without the legacy file\n' "$MANAGE" "$LABEL_FILE"
    printf '        refuses ethernet.force_enabled and goes dark after the first reboot.\n'
fi

if [ -e "$FORCE_BOOT" ]; then
    skip_test "ETHF-08" "remote override without legacy label — flash marker present, it would win"
elif [ -z "$IDENTITY" ] || [ -z "$REMOTE" ]; then
    skip_test "ETHF-08" "remote override without legacy label — needs ga-identity.json + fleet marker (identity=${IDENTITY:-none} marker=${REMOTE:-none})"
else
    _stash=""
    if [ -e "$LABEL_FILE" ]; then
        _stash="${LABEL_FILE}.ethf08"
        cp -p "$LABEL_FILE" "$_stash" && rm -f "$LABEL_FILE"
        # shellcheck disable=SC2064
        trap "[ -e '$_stash' ] && mv -f '$_stash' '$LABEL_FILE'" EXIT INT TERM
    fi
    SRC8=$("$MANAGE" status 2>/dev/null | sed -n 's/^ethernet_source=//p')
    if [ -n "$_stash" ]; then
        mv -f "$_stash" "$LABEL_FILE"
        trap - EXIT INT TERM
    fi
    printf '        identity=%s marker=%s legacy_label=%s -> source=%s\n' \
        "$IDENTITY" "$REMOTE" "$([ -e "$LABEL_FILE" ] && echo present || echo absent)" "${SRC8:-?}"
    run_test "ETHF-08" "remote override accepted without the legacy label file" "[ \"$SRC8\" = force-config ]"
fi

suite_end
