# shellcheck shell=sh
# os-version.sh — order HAOS versions (16.3.1.10) and the images named after them.
# Sourced, POSIX sh. No side effects on load.
#
# WHY THIS FILE EXISTS
#   From BOSv1.5.0-rc2 the OS version is 16.3.1.10. Every 1.3.x and 1.4.x image
#   shipped as 16.3.1.9, so a two-digit last field is new. A plain `sort`, a
#   string `<` or a float reading of "1.10" puts 16.3.1.10 BELOW 16.3.1.9
#   ("1" < "9"; 1.10 < 1.9). Anything here that has to say which of two OS
#   versions is newer says it through os_version_cmp, which compares the
#   dot-separated fields as integers, left to right.
#
#   The fixture that holds these helpers to that order is
#   tests/gates/os_version_order/selftest.sh (run in CI). It also proves that a
#   lexical and a float variant of os_version_cmp fail it.

# os_version_valid V — digits separated by single dots, 2..6 fields.
os_version_valid() {
	case "$1" in
		"" | *[!0-9.]* | .* | *. | *..*) return 1 ;;
	esac
	case "$1" in
		*.*) ;;
		*) return 1 ;;
	esac
	[ "$(printf '%s' "$1" | tr -cd . | wc -c)" -le 5 ]
}

# os_version_cmp A B — prints -1, 0 or 1 (A older, equal, newer than B).
# Fields compare as integers; a missing field counts as 0 (16.3.1 == 16.3.1.0).
# Exit status 2, nothing printed, when either side is malformed.
os_version_cmp() {
	os_version_valid "$1" || return 2
	os_version_valid "$2" || return 2
	_ovc_a="$1."
	_ovc_b="$2."
	while [ -n "$_ovc_a" ] || [ -n "$_ovc_b" ]; do
		_ovc_x="${_ovc_a%%.*}"; _ovc_a="${_ovc_a#*.}"
		_ovc_y="${_ovc_b%%.*}"; _ovc_b="${_ovc_b#*.}"
		# Strip leading zeros so "08" is never read as octal.
		_ovc_x="${_ovc_x#"${_ovc_x%%[!0]*}"}"; _ovc_x="${_ovc_x:-0}"
		_ovc_y="${_ovc_y#"${_ovc_y%%[!0]*}"}"; _ovc_y="${_ovc_y:-0}"
		if [ "$_ovc_x" -gt "$_ovc_y" ]; then echo 1; return 0; fi
		if [ "$_ovc_x" -lt "$_ovc_y" ]; then echo -1; return 0; fi
	done
	echo 0
}

# newest_bos_image FILE... — prints the newest disk image among the arguments:
# highest OS version, then the latest 14-digit build timestamp. Names are the
# ones ga_build.sh writes: bos_<board>-<ver>_<tag>_<YYYYmmddHHMMSS>.img.xz.
# Provisioning images (…_provisioning.img.xz) and names that do not parse are
# skipped. Exit status 1 when nothing qualifies.
newest_bos_image() {
	_nbi_best=""; _nbi_bv=""; _nbi_bt=""
	for _nbi_f in "$@"; do
		_nbi_n="${_nbi_f##*/}"
		case "$_nbi_n" in
			*_provisioning.img.xz) continue ;;
			bos_*-*_*_*.img.xz) ;;
			*) continue ;;
		esac
		_nbi_r="${_nbi_n#*-}"           # <ver>_<tag>_<ts>.img.xz
		_nbi_v="${_nbi_r%%_*}"
		_nbi_t="${_nbi_r%.img.xz}"; _nbi_t="${_nbi_t##*_}"
		os_version_valid "$_nbi_v" || continue
		case "$_nbi_t" in
			[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
			*) continue ;;
		esac
		if [ -z "$_nbi_best" ]; then
			_nbi_best="$_nbi_f"; _nbi_bv="$_nbi_v"; _nbi_bt="$_nbi_t"; continue
		fi
		_nbi_c="$(os_version_cmp "$_nbi_v" "$_nbi_bv")" || continue
		# 14-digit timestamps fit a 64-bit shell integer.
		if [ "$_nbi_c" = 1 ] || { [ "$_nbi_c" = 0 ] && [ "$_nbi_t" -gt "$_nbi_bt" ]; }; then
			_nbi_best="$_nbi_f"; _nbi_bv="$_nbi_v"; _nbi_bt="$_nbi_t"
		fi
	done
	[ -n "$_nbi_best" ] || return 1
	printf '%s\n' "$_nbi_best"
}
