#!/bin/sh
# SSH access test suite — runs ON the device
# Verifies that the V1.2-clean OS image's baked SSH authorized_keys was
# correctly seeded onto the overlay partition and dropbear came up.
#
# Why this exists: HAOS dropbear has
#   ConditionFileNotEmpty=/root/.ssh/authorized_keys
# /root/.ssh is bind-mounted from /mnt/overlay/root/.ssh (the overlay
# partition, empty on a freshly-flashed device). Without the seed step
# in /usr/libexec/hassos-overlay, dropbear NEVER starts on first boot
# and the device is unreachable except via serial.
#
# Discovered live on KIB-SON-31 2026-05-27 — device looked healthy, had
# .ga_converged etc., but port 22222 was always refused because
# authorized_keys was missing from the overlay.
#
# Counterpart build tests: SSH-01..05 in run_build_tests.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "SSH access"

ROOTFS_AK="/usr/share/ga-ssh/authorized_keys"
OVERLAY_AK="/mnt/overlay/root/.ssh/authorized_keys"
LIVE_AK="/root/.ssh/authorized_keys"

# =========================================================================
# Rootfs source-of-truth (baked-in)
# =========================================================================

run_test "SSH-D-01" "baked authorized_keys on rootfs at /usr/share/ga-ssh/" \
  "test -f $ROOTFS_AK"

run_test "SSH-D-02" "baked authorized_keys non-empty with at least one OpenSSH pubkey" \
  "grep -cE '^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-) ' $ROOTFS_AK 2>/dev/null | awk '\$1 > 0 {exit 0} {exit 1}'"

# =========================================================================
# Overlay seed — hassos-overlay copied the baked file on first boot
# =========================================================================

run_test "SSH-D-03" "overlay seed present at /mnt/overlay/root/.ssh/authorized_keys" \
  "test -f $OVERLAY_AK"

run_test "SSH-D-04" "overlay authorized_keys has correct perms (0600)" \
  "test \"\$(stat -c '%a' $OVERLAY_AK 2>/dev/null)\" = '600'"

run_test "SSH-D-05" "overlay /root/.ssh dir has correct perms (0700)" \
  "test \"\$(stat -c '%a' /mnt/overlay/root/.ssh 2>/dev/null)\" = '700'"

# Content match: at least every baked key must be present in the overlay.
# We don't require strict equality (operator may have added their own
# additional keys at runtime — the seed is non-destructive).
run_test "SSH-D-06" "overlay authorized_keys contains all baked pubkeys" \
  "grep -E '^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-) ' $ROOTFS_AK | while read -r k; do grep -qxF \"\$k\" $OVERLAY_AK || exit 1; done"

# =========================================================================
# Bind mount + live exposure
# =========================================================================

run_test "SSH-D-07" "/root/.ssh is a bind mount" \
  "mountpoint -q /root/.ssh"

run_test "SSH-D-08" "live /root/.ssh/authorized_keys readable through the bind" \
  "test -f $LIVE_AK && test -s $LIVE_AK"

# =========================================================================
# Dropbear service + listener
# =========================================================================

run_test "SSH-D-09" "dropbear.service active" \
  "systemctl is-active dropbear >/dev/null"

# Dropbear's `ConditionFileNotEmpty=/root/.ssh/authorized_keys` must be SAT
# (the unit would skip-with-condition-failed if not).
run_test "SSH-D-10" "dropbear unit ConditionFileNotEmpty satisfied (no condition-failed)" \
  "! systemctl show dropbear -p ConditionResult --value 2>/dev/null | grep -q '^no$'"

run_test "SSH-D-11" "dropbear listening on port 22222" \
  "ss -tln 2>/dev/null | grep -q ':22222' || netstat -tln 2>/dev/null | grep -q ':22222'"

# Pid file from the unit's PIDFile=
run_test "SSH-D-12" "dropbear pid file exists" \
  "test -f /run/dropbear.pid"

# =========================================================================
# Loopback SSH banner — implicit
# =========================================================================
# We previously had SSH-D-13 doing a banner-exchange probe via nc.
# Dropped 2026-05-27 because BusyBox-iHost has no nc / ssh-keyscan /
# bash-/dev/tcp, and the test runner's OWN SSH session (used to push and
# invoke this script) is already proof that the listener accepts a banner
# exchange end-to-end. D-09 + D-11 + D-12 cover service-state; the test
# runner connecting at all proves the banner half. No replacement.

# =========================================================================
# Summary
# =========================================================================
suite_end
