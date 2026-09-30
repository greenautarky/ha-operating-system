#!/bin/sh
# SSH access test suite — runs ON the device
# Verifies that the V1.2-clean OS image's baked SSH authorized_keys was
# correctly seeded onto the overlay partition and the SSH server came up.
# The server is OpenSSH sshd since ADR-0019 step 1 (dropbear before that);
# the invariant is the same and lives in the unit drop-in:
#
# Why this exists: the host SSH unit has
#   ConditionFileNotEmpty=/root/.ssh/authorized_keys
# /root/.ssh is bind-mounted from /mnt/overlay/root/.ssh (the overlay
# partition, empty on a freshly-flashed device). Without the seed step
# in /usr/libexec/hassos-overlay, the server NEVER starts on first boot
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
# SHARED PLANE ONLY. On the certificate plane sshd reads the baked file
# directly (SSH-D-24), and a device updated over the air keeps the overlay
# file an older image seeded — which never held the break-glass key.
if [ -s /etc/ssh/ga_user_ca.pub ]; then
  skip_test "SSH-D-06" "overlay seed content — certificate plane reads the baked file itself (SSH-D-24)"
else
  run_test "SSH-D-06" "overlay authorized_keys contains all baked pubkeys" \
    "grep -E '^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-) ' $ROOTFS_AK | while read -r k; do grep -qxF \"\$k\" $OVERLAY_AK || exit 1; done"
fi

# =========================================================================
# Bind mount + live exposure
# =========================================================================

run_test "SSH-D-07" "/root/.ssh is a bind mount" \
  "mountpoint -q /root/.ssh"

run_test "SSH-D-08" "live /root/.ssh/authorized_keys readable through the bind" \
  "test -f $LIVE_AK && test -s $LIVE_AK"

# =========================================================================
# sshd service + listener + per-device host key
# =========================================================================

run_test "SSH-D-09" "sshd.service active" \
  "systemctl is-active sshd >/dev/null"

# The unit's `ConditionFileNotEmpty=/root/.ssh/authorized_keys` must be SAT
# (the unit would skip-with-condition-failed if not).
run_test "SSH-D-10" "sshd unit ConditionFileNotEmpty satisfied (no condition-failed)" \
  "! systemctl show sshd -p ConditionResult --value 2>/dev/null | grep -q '^no$'"

run_test "SSH-D-11" "sshd listening on port 22222" \
  "ss -tln 2>/dev/null | grep -q ':22222' || netstat -tln 2>/dev/null | grep -q ':22222'"

# Buildroot's unit runs `ssh-keygen -A` as ExecStartPre, which would write
# into the read-only /etc/ssh. The drop-in clears it; if that override is
# ever lost, this is the line that shows it (the unit would then carry two
# ExecStartPre entries, the first of them the upstream one).
run_test "SSH-D-12" "sshd ExecStartPre is ga-sshd-prepare only (upstream ssh-keygen -A cleared)" \
  "systemctl show sshd -p ExecStartPre --value 2>/dev/null | grep -q 'ga-sshd-prepare' \
   && ! systemctl show sshd -p ExecStartPre --value 2>/dev/null | grep -q 'ssh-keygen -A'"

# The ONE host key: generated on first boot, persisted through the bind mount
# so it survives an OTA — a device whose host key changes on every update is
# one that nobody can verify. Both halves are asserted: the bind is live AND
# the key on the overlay is the key sshd reads.
run_test "SSH-D-13" "/etc/ssh/keys is a bind mount from the overlay" \
  "mountpoint -q /etc/ssh/keys"

run_test "SSH-D-14" "ed25519 host key present under /etc/ssh/keys (0600)" \
  "test -s /etc/ssh/keys/ssh_host_ed25519_key \
   && [ \"\$(stat -c %a /etc/ssh/keys/ssh_host_ed25519_key)\" = 600 ]"

run_test "SSH-D-15" "host key on the overlay is the one sshd serves (same file through the bind)" \
  "test -s /mnt/overlay/etc/ssh/keys/ssh_host_ed25519_key \
   && cmp -s /mnt/overlay/etc/ssh/keys/ssh_host_ed25519_key /etc/ssh/keys/ssh_host_ed25519_key"

# No host key baked into the rootfs: one that is baked is the same on every
# device, which makes host verification meaningless while looking like it works.
run_test "SSH-D-16" "no host key baked into the read-only rootfs" \
  "! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1"

# sshd's privilege-separation dir is on zram /var and must be re-created every
# boot by ga-sshd-prepare; without it sshd exits at start.
run_test "SSH-D-17" "/var/empty exists, root-owned, not group/world-writable" \
  "test -d /var/empty && [ \"\$(stat -c %U:%a /var/empty)\" = root:755 ]"

# Nothing of the old server remains: no unit, no binary, no second listener.
run_test "SSH-D-18" "dropbear is gone (no unit, no binary)" \
  "! systemctl cat dropbear >/dev/null 2>&1 && ! command -v dropbear >/dev/null 2>&1"

# =========================================================================
# Certificate plane (ADR-0019 step 2, BOSv1.4.0+) — the device-side half.
# =========================================================================
# Which plane applies comes from the IMAGE (a baked user CA), never from a
# guess. On a pre-cut image these are skipped, and SSH-D-19 says so.
# The login matrix itself (cert accepted, other-device cert refused, shared
# key refused, break-glass accepted) runs from the operator's machine:
# scripts/ops/ga-ssh-cert-plane-verify.sh — this box has no client to test with.
GA_LEGACY_FLEET_KEY_FP="SHA256:T+Pt2vUEG+lYv0t5qTMdFyd2Kchx6mjkOR3YZaVqcjE"
if [ -s /etc/ssh/ga_user_ca.pub ]; then
  run_test "SSH-D-19" "sshd EFFECTIVELY trusts the baked user CA (sshd -T, not the file)" \
    "sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | grep -qx 'trustedusercakeys /etc/ssh/ga_user_ca.pub'"
  run_test "SSH-D-20" "sshd EFFECTIVELY scopes certificates per device (AuthorizedPrincipalsFile)" \
    "sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | grep -qx 'authorizedprincipalsfile /etc/ssh/principals/%u'"
  run_test "SSH-D-21" "/etc/ssh/principals is a bind mount from the overlay" \
    "mountpoint -q /etc/ssh/principals"
  run_test "SSH-D-22" "principals for root: hardware anchor present, no 'kibu', no wildcard" \
    "test -s /etc/ssh/principals/root && ! grep -qxE 'kibu|\\*' /etc/ssh/principals/root \
     && grep -qvE '^KIB-SON-' /etc/ssh/principals/root"
  run_test "SSH-D-23" "principals for root: fleet label KIB-SON-XXXXXXXX present (from ga_manager)" \
    "grep -qxE 'KIB-SON-[0-9]{8}' /etc/ssh/principals/root"
  # SSH-D-24/27/28/29 hold on a device updated over the air as well as on a
  # fresh flash: its overlay authorized_keys was seeded by an older image (the
  # pre-cut fleet key, no break-glass), and the image enforces the plane in
  # what sshd reads rather than in that file. Run them on an OTA-updated
  # canary, not only on a clean flash.
  run_test "SSH-D-24" "sshd EFFECTIVELY reads the baked break-glass file first; it holds exactly ONE key, not the pre-cut fleet key" \
    "sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | grep -qE '^authorizedkeysfile $ROOTFS_AK( |\$)' \
     && [ \"\$(grep -cE '^(ssh-|ecdsa-|sk-)' $ROOTFS_AK)\" = 1 ] \
     && ! ssh-keygen -lf $ROOTFS_AK 2>/dev/null | grep -qF '$GA_LEGACY_FLEET_KEY_FP'"
  run_test "SSH-D-25" "ga-ssh-posture reports the certificate plane" \
    "[ \"\$(/usr/libexec/ga-ssh-posture 2>/dev/null)\" = ca ]"
  run_test "SSH-D-27" "sshd EFFECTIVELY refuses the pre-cut fleet key (RevokedKeys lists it, whatever the overlay holds)" \
    "sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | grep -qx 'revokedkeys /etc/ssh/ga_revoked_keys' \
     && ssh-keygen -lf /etc/ssh/ga_revoked_keys 2>/dev/null | grep -qF '$GA_LEGACY_FLEET_KEY_FP'"
  # The start condition must name the file sshd reads first, or sshd depends
  # on the overlay copy it no longer needs.
  run_test "SSH-D-28" "sshd unit start condition is the baked break-glass file" \
    "[ \"\$(systemctl cat sshd 2>/dev/null | sed -n 's/^ConditionFileNotEmpty=\(..*\)\$/\1/p' | tail -1)\" = '$ROOTFS_AK' ]"
  # An unreadable revocation list makes sshd refuse EVERY public key,
  # certificates included; this is the line that names that cause.
  run_test "SSH-D-29" "sshd reads the revocation list without errors (journal since boot)" \
    "! journalctl -b -u sshd --no-pager 2>/dev/null | grep -q 'in revoked keys file'"
  run_test "SSH-D-26" "host key published to the /share bridge for the fleet-manager register" \
    "jq -er '.ssh_host_key' /mnt/data/supervisor/share/ga-enroll-state.json 2>/dev/null \
     | grep -qx \"\$(awk '{print \$1\" \"\$2}' /etc/ssh/keys/ssh_host_ed25519_key.pub)\""
else
  skip_test "SSH-D-19" "certificate plane checks — no user CA baked (pre-BOSv1.4.0 image, shared plane)"
fi

# =========================================================================
# Loopback SSH banner — implicit
# =========================================================================
# We previously had a banner-exchange probe via nc.
# Dropped 2026-05-27 because BusyBox-iHost has no nc / ssh-keyscan /
# bash-/dev/tcp, and the test runner's OWN SSH session (used to push and
# invoke this script) is already proof that the listener accepts a banner
# exchange end-to-end. D-09 + D-11 + D-12 cover service-state; the test
# runner connecting at all proves the banner half. No replacement.
# SSH-D-13..18 were added with the OpenSSH swap (ADR-0019 step 1).

# =========================================================================
# Summary
# =========================================================================
suite_end
