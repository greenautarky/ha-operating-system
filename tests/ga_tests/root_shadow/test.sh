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
#   RSD-10      boot ordering on THIS boot: the unit's first run came after the
#               overlay mount and before sysinit.target, it applied what the
#               hash file says, every serial getty and rescue.service are
#               ordered after sysinit.target, and no ordering cycle was broken
#   RSD-11      survival across an OS update: compares with what the previous
#               run of this suite recorded on the data partition. Without an
#               update since then it is a SKIP; GA_RS_EXPECT_OTA=1 (the run
#               right after an update) turns that SKIP into a FAIL
#   RSD-12      `ga-root-shadow --early` on a running device changes nothing
#   RSD-13      GA_RS_RESCUE_DRILL=1 only: the recovery path for a device whose
#               own password is lost — remove the hash file, restart the unit
#               → the image's password applies; put it back, restart → the
#               device password applies again. Restores the file on any exit.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
. "$SCRIPT_DIR/verdicts.sh"

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

# ── RSD-10 boot ordering (measured on this boot) ────────────────────────────
BOOTREC="$(cat /run/ga-root-shadow/boot 2>/dev/null)"
OV_US="$(systemctl show -p ActiveEnterTimestampMonotonic --value mnt-overlay.mount 2>/dev/null)"
SI_US="$(systemctl show -p ActiveEnterTimestampMonotonic --value sysinit.target 2>/dev/null)"
run_test_show "RSD-10a" "the boot's own run: after the overlay mount, before sysinit.target" \
	"rs_boot_order '$BOOTREC' '$OV_US' '$SI_US'"
HAVE_HF=0; [ -e "$HF" ] && HAVE_HF=1
HF_NEW=0
if [ "$HAVE_HF" = 1 ]; then
	BOOT_EPOCH=$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) ))
	[ "$(stat -c %Y "$HF")" -gt "$BOOT_EPOCH" ] && HF_NEW=1
fi
BS_MSG="$(rs_boot_state "$BOOTREC" "$HAVE_HF" "$HF_NEW")"; BS_RC=$?
if [ "$BS_RC" = 2 ]; then
	skip_test "RSD-10b" "the boot's own run applied what the hash file says" "$BS_MSG"
else
	run_test_show "RSD-10b" "the boot's own run applied what the hash file says" "echo '$BS_MSG'; [ $BS_RC -eq 0 ]"
fi
# Every login path that asks for root's password starts after sysinit.target.
# Fail closed when no serial getty is found: zero inspected is not a pass.
GETTYS="$(systemctl list-units --all --plain --no-legend 'serial-getty@*.service' 2>/dev/null | awk '{ print $1 }')"
after_sysinit() { systemctl show -p After --value "$1" | tr ' ' '\n' | grep -qx sysinit.target; }
gettys_after_sysinit() {
	n=0
	for g in $GETTYS rescue.service; do
		after_sysinit "$g" || { echo "$g is not ordered after sysinit.target"; return 1; }
		case "$g" in serial-getty@*) n=$((n + 1)) ;; esac
	done
	[ "$n" -ge 1 ] || { echo "no serial getty found"; return 1; }
	echo "$n serial getty unit(s) + rescue.service ordered after sysinit.target"
}
run_test_show "RSD-10c" "every serial getty and rescue.service start after sysinit.target" "gettys_after_sysinit"
if command -v journalctl >/dev/null 2>&1; then
	run_test_show "RSD-10d" "no ordering cycle involving ga-root-shadow on this boot" \
		"! journalctl -b --no-pager -o cat 2>/dev/null | grep -i 'ordering cycle' | grep ga-root-shadow"
else
	run_test "RSD-10d" "journalctl available to check for ordering cycles" "false"
fi

# ── RSD-11 survival across an OS update ─────────────────────────────────────
OTA_REC=/mnt/data/.ga_root_shadow_test
SLOT="$(rauc status 2>/dev/null | sed -n 's/^Booted from: *\([^ ]*\).*/\1/p' | head -n1)"
VER="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')"
SUM=none; [ -e "$HF" ] && SUM="$(sha256sum < "$HF" | awk '{ print $1 }')"
OTA_MSG="$(rs_ota_survival "$OTA_REC" "${SLOT:-unknown}" "${VER:-unknown}" "$SUM")"; OTA_RC=$?
case "$OTA_RC" in
	0) run_test_show "RSD-11" "the device password survived the OS update" "echo '$OTA_MSG'" ;;
	1) run_test_show "RSD-11" "the device password survived the OS update" "echo '$OTA_MSG'; false" ;;
	*) if [ "${GA_RS_EXPECT_OTA:-0}" = 1 ]; then
		run_test_show "RSD-11" "the device password survived the OS update (GA_RS_EXPECT_OTA=1)" "echo '$OTA_MSG'; false"
	   else
		skip_test "RSD-11" "survival across an OS update" "$OTA_MSG"
	   fi ;;
esac
if [ -n "$SLOT" ] && [ -n "$VER" ]; then
	( umask 077; printf 'slot=%s\nversion=%s\nhashsum=%s\n' "$SLOT" "$VER" "$SUM" > "$OTA_REC" )
else
	run_test "RSD-11r" "booted slot and OS version readable (to record this run)" "false"
fi

# ── RSD-12 --early on a running device is a no-op ───────────────────────────
root_field() { awk -F: '$1 == "root" { print $2 }' /etc/shadow; }
shadow_mounts() { awk '$5 == "/etc/shadow"' /proc/self/mountinfo | wc -l; }
# shellcheck disable=SC2034  # read inside run_test's eval
B_FIELD="$(root_field)"; B_MOUNTS="$(shadow_mounts)"
/usr/libexec/ga-root-shadow --early >/dev/null 2>&1; E_RC=$?
run_test "RSD-12" "--early on a running device: exit 0, same root field, same mounts" \
	"[ $E_RC -eq 0 ] && [ \"\$(root_field)\" = \"\$B_FIELD\" ] && [ \"\$(shadow_mounts)\" = '$B_MOUNTS' ]"

# ── RSD-13 rescue drill (opt-in) ────────────────────────────────────────────
if [ "${GA_RS_RESCUE_DRILL:-0}" = 1 ] && [ -e "$HF" ]; then
	# The copy stays on the overlay, next to the original: a drill cut short
	# (power loss, a killed session) must not leave the only copy in /run.
	KEEP="$HF.drill"
	( umask 077; cp -p "$HF" "$KEEP" )
	KEEP_SUM="$(sha256sum < "$KEEP" | awk '{ print $1 }')"
	restore() {
		[ -s "$KEEP" ] || return 0
		if cp -p "$KEEP" "$HF.new" && chmod 0600 "$HF.new" && mv -f "$HF.new" "$HF" && sync \
			&& systemctl restart "$U"; then
			rm -f "$KEEP"; return 0
		fi
		echo "RSD-13: RESTORE FAILED — the device password is kept in $KEEP; copy it back to $HF and restart $U" >&2
		return 1
	}
	trap 'restore' EXIT INT TERM HUP
	rm -f "$HF" && sync && systemctl restart "$U"
	run_test_show "RSD-13a" "hash file removed + restart → state 'start', the image's shadow" \
		"[ \"\$(state)\" = start ] && ! shadow_mounted"
	restore; R_RC=$?
	run_test_show "RSD-13b" "hash file restored + restart → state 'rotated', the same device password" \
		"[ $R_RC -eq 0 ] && [ \"\$(state)\" = rotated ] && shadow_mounted && [ \"\$(sha256sum < '$HF' | awk '{ print \$1 }')\" = '$KEEP_SUM' ] && [ \"\$(root_field)\" = \"\$(cat '$HF')\" ]"
	trap - EXIT INT TERM HUP
elif [ "${GA_RS_RESCUE_DRILL:-0}" = 1 ]; then
	run_test "RSD-13" "rescue drill needs a device password on the device" "false"
else
	skip_test "RSD-13" "rescue drill" "GA_RS_RESCUE_DRILL=1 not set"
fi

suite_end
