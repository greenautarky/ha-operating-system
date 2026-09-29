#!/bin/sh
# root_shadow — the device's own root password is in effect (ADR-0039 D4/D4b/D6).
#
# Runs ON the device (root). The host-side logic is pinned by selftest.sh; this
# suite checks the installed mechanism and the state it produced on this boot.
#
#   RSD-01..04  the unit is installed, enabled, ordered before sysinit.target,
#               ran successfully, and emergency/rescue call it with --early
#   RSD-05      the published status exists and matches what is mounted —
#               a missing status file is a FAIL, never a skip (D6)
#   RSD-06      with a hash file: /etc/shadow is the merged copy, root's field
#               equals the hash file, every other line equals the image's
#   RSD-07      GA_RS_EXPECT=rotated|start: this device must be in that state
#               (a provisioned device must be "rotated")
#   RSD-08/09   GA_RS_DEVICE_PW_FILE / GA_RS_START_PW_FILE (0600 files on the
#               device): the device password matches the effective root hash,
#               the start password does not. The serial LOGIN proof of the
#               same pair runs from the bench (ga-flasher-py
#               root_console_credentials.py verify), because root logins are
#               only permitted on the serial ttys.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "root_shadow (per-device root password)"

HF=/mnt/overlay/etc/ga-root-pw-hash
ST=/mnt/data/supervisor/share/ga-root-shadow-status.json
U=ga-root-shadow.service

# GA_RS_HAND_INSTALL=1: the files were installed at runtime under /run (a
# bench proof before a bake), where systemd reports "enabled-runtime".
EN=enabled
[ "${GA_RS_HAND_INSTALL:-0}" = 1 ] && EN=enabled-runtime
run_test "RSD-01" "ga-root-shadow is installed and $EN" \
	"[ -x /usr/libexec/ga-root-shadow ] && [ \"\$(systemctl is-enabled $U 2>/dev/null)\" = $EN ]"
run_test_show "RSD-02" "ordered before sysinit.target, after the overlay" \
	"systemctl show -p Before --value $U | tr ' ' '\n' | grep -qx sysinit.target && systemctl show -p After --value $U | tr ' ' '\n' | grep -qx hassos-overlay.service"
run_test_show "RSD-03" "ran on this boot and succeeded" \
	"[ \"\$(systemctl show -p Result --value $U)\" = success ] && [ \"\$(systemctl show -p ActiveState --value $U)\" = active ]"
for u in emergency rescue; do
	run_test "RSD-04-$u" "$u.service calls ga-root-shadow --early" \
		"systemctl show -p ExecStartPre --value $u.service | grep -q '/usr/libexec/ga-root-shadow --early'"
done

shadow_mounted() { awk '$5 == "/etc/shadow" { f = 1 } END { exit !f }' /proc/self/mountinfo; }
state() { sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p' "$ST" 2>/dev/null; }
boot_id() { sed -n 's/.*"boot_id": *"\([^"]*\)".*/\1/p' "$ST" 2>/dev/null; }

run_test_show "RSD-05a" "status file present and from THIS boot" \
	"[ -f '$ST' ] && [ \"\$(boot_id)\" = \"\$(cat /proc/sys/kernel/random/boot_id)\" ]"
if [ -e "$HF" ]; then
	run_test_show "RSD-05b" "hash file present → status 'rotated' and /etc/shadow is bind-mounted" \
		"[ \"\$(state)\" = rotated ] && shadow_mounted"
	# Compared in-shell; nothing secret is printed.
	run_test "RSD-06a" "root's field in /etc/shadow equals the hash file" \
		"[ \"\$(awk -F: '\$1 == \"root\" { print \$2 }' /etc/shadow)\" = \"\$(cat '$HF')\" ]"
	V="$(mktemp -d)"
	if mount --bind / "$V" 2>/dev/null; then
		run_test "RSD-06b" "every other line equals the image's /etc/shadow" \
			"[ \"\$(grep -v '^root:' /etc/shadow)\" = \"\$(grep -v '^root:' '$V/etc/shadow')\" ]"
		run_test "RSD-06c" "the image's own root field differs from the applied one" \
			"[ \"\$(awk -F: '\$1 == \"root\" { print \$2 }' '$V/etc/shadow')\" != \"\$(cat '$HF')\" ]"
		umount "$V"
	else
		run_test "RSD-06b" "could view the image's /etc/shadow (bind of /)" "false"
	fi
	rmdir "$V" 2>/dev/null
else
	run_test_show "RSD-05b" "no hash file → status 'start' and /etc/shadow is the image's" \
		"[ \"\$(state)\" = start ] && ! shadow_mounted"
fi

if [ -n "${GA_RS_EXPECT:-}" ]; then
	run_test_show "RSD-07" "this device is in state '$GA_RS_EXPECT'" \
		"[ \"\$(state)\" = '$GA_RS_EXPECT' ]"
fi

# crypt_ok <password-file> — the file's password matches the effective root hash.
crypt_ok() {
	h="$(awk -F: '$1 == "root" { print $2 }' /etc/shadow)"
	salt="$(printf '%s' "$h" | cut -d'$' -f3)"
	[ "$(openssl passwd -6 -salt "$salt" -stdin < "$1" 2>/dev/null)" = "$h" ]
}
if [ -n "${GA_RS_DEVICE_PW_FILE:-}" ] || [ -n "${GA_RS_START_PW_FILE:-}" ]; then
	if command -v openssl >/dev/null 2>&1; then
		[ -n "${GA_RS_DEVICE_PW_FILE:-}" ] && run_test "RSD-08" "the device password matches the effective root hash" \
			"crypt_ok '$GA_RS_DEVICE_PW_FILE'"
		[ -n "${GA_RS_START_PW_FILE:-}" ] && run_test "RSD-09" "the start password does NOT match the effective root hash" \
			"[ -s '$GA_RS_START_PW_FILE' ] && ! crypt_ok '$GA_RS_START_PW_FILE'"
	else
		run_test "RSD-08" "openssl available to check the password files" "false"
	fi
else
	skip_test "RSD-08" "password files" "GA_RS_DEVICE_PW_FILE / GA_RS_START_PW_FILE not given"
fi

suite_end
