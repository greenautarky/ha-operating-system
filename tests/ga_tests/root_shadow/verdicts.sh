#!/bin/sh
# root_shadow verdicts — the decisions of the device suite (test.sh), kept
# free of device access so selftest.sh can drive them with must-pass and
# must-fail inputs in CI. test.sh measures; these functions judge.
#
# Each function prints one line (the reason) and returns 0 for pass,
# 1 for fail, 2 for "cannot be decided on this run" (the caller decides
# whether that is a skip or a failure).

# rs_boot_order <record> <overlay_active_us> <sysinit_active_us>
#   <record>             contents of /run/ga-root-shadow/boot: "<uptime_s> <state>"
#   <overlay_active_us>  mnt-overlay.mount ActiveEnterTimestampMonotonic
#   <sysinit_active_us>  sysinit.target ActiveEnterTimestampMonotonic
# Pass only when the boot's own run happened after the overlay was mounted
# and before sysinit.target was reached (so before every getty and before
# rescue.service, which are ordered after sysinit.target).
rs_boot_order() {
	_rec="$1"; _ov="$2"; _si="$3"
	_up="$(printf '%s' "$_rec" | awk '{ print $1 }')"
	case "$_up" in
		''|*[!0-9.]*) echo "no boot record — the unit did not run during this boot"; return 1 ;;
	esac
	case "$_ov" in ''|0|*[!0-9]*) echo "overlay mount time unknown ($_ov)"; return 1 ;; esac
	case "$_si" in ''|0|*[!0-9]*) echo "sysinit.target time unknown ($_si)"; return 1 ;; esac
	awk -v up="$_up" -v ov="$_ov" -v si="$_si" 'BEGIN {
		u = up * 1000000
		# /proc/uptime has 10 ms resolution and is truncated, so the record
		# can read up to 10 ms early: allow that much before the overlay.
		if (u + 10000 < ov) { printf "ran at %.2fs, BEFORE the overlay was mounted (%.2fs)\n", up, ov / 1e6; exit 1 }
		if (u > si)         { printf "ran at %.2fs, AFTER sysinit.target (%.2fs)\n", up, si / 1e6; exit 1 }
		printf "ran at %.2fs: overlay %.2fs <= run <= sysinit.target %.2fs\n", up, ov / 1e6, si / 1e6
	}'
}

# rs_boot_state <record> <hash_file_present 0|1> [<hash_file_written_this_boot 0|1>]
# What the BOOT applied, not what a later runtime restart applied. A hash file
# written after this boot started (the station step, without a reboot since)
# cannot have been applied by the boot: 2, reboot and measure again.
rs_boot_state() {
	_st="$(printf '%s' "$1" | awk '{ print $2 }')"
	if [ "$2" = 1 ]; then
		[ "$_st" = rotated ] && { echo "the boot applied the device password"; return 0; }
		if [ "${3:-0}" = 1 ]; then
			echo "the hash file was written after this boot started — reboot, then measure"; return 2
		fi
		echo "hash file present, but the boot's own run ended in '${_st:-nothing}'"; return 1
	fi
	[ "$_st" = start ] && { echo "no hash file, the boot left the image's password"; return 0; }
	echo "no hash file, but the boot's own run ended in '${_st:-nothing}'"; return 1
}

# rs_ota_survival <previous-record-file> <slot> <version> <hashsum>
#   <previous-record-file>  written by the previous run (may be absent):
#                           lines slot=…, version=…, hashsum=…
#   <hashsum>               sha256 of the hash file now, or "none"
# 0  an OS update happened since the previous run and the device password
#    survived it unchanged
# 1  the device password is gone or changed (with or without an update)
# 2  no OS update since the previous run, or no previous run: nothing to judge
rs_ota_survival() {
	_f="$1"; _slot="$2"; _ver="$3"; _sum="$4"
	if [ ! -s "$_f" ]; then
		echo "no previous run recorded on this device"; return 2
	fi
	_pslot="$(sed -n 's/^slot=//p' "$_f")"
	_pver="$(sed -n 's/^version=//p' "$_f")"
	_psum="$(sed -n 's/^hashsum=//p' "$_f")"
	if [ -n "$_psum" ] && [ "$_psum" != none ]; then
		if [ "$_sum" = none ]; then
			echo "the device password was present on $_pver ($_pslot) and is GONE now on $_ver ($_slot)"; return 1
		fi
		if [ "$_sum" != "$_psum" ]; then
			echo "the device password changed between $_pver ($_pslot) and $_ver ($_slot)"; return 1
		fi
	fi
	if [ "$_pslot" = "$_slot" ] && [ "$_pver" = "$_ver" ]; then
		echo "no OS update since the previous run ($_ver, $_slot)"; return 2
	fi
	if [ -z "$_psum" ] || [ "$_psum" = none ]; then
		echo "updated $_pver ($_pslot) -> $_ver ($_slot), but there was no device password before it"; return 2
	fi
	echo "device password unchanged across the update $_pver ($_pslot) -> $_ver ($_slot)"
	return 0
}
