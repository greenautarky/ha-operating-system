# shellcheck shell=bash
# ga-release-label.sh - the ONE place that spells the human-facing GA release
# label on artifacts and displays (ADR-0055, Thomas 2026-11-19). Sourced.
#
# Human-facing (renamed after the ga_release):
#   artifact file names    <ga_release>_<board>_<osver>.{raucb,img.xz}
#   /etc/os-release        PRETTY_NAME="GreenAutarky <ga_release> (HAOS <osver>)"
#   login banner           /etc/motd + /etc/issue carry the same label
#   RAUC bundle            [update] description= (patches-haos/0114)
# Technical (deliberately NOT touched - devices consume them):
#   VERSION_ID / CPE_NAME (Supervisor reads `hassos` from the channel file and
#   the CPE), RAUC compatible/version, the OTA store file name
#   haos_<board>-<osver>.raucb, `uname -r`, /etc/ga-release (the source of truth).

# Labels: BOSv1.6.0, BOSv1.6.0-rc3, BOSv1.6.0-dev16.
GA_RELEASE_LABEL_RE='BOSv[0-9]+\.[0-9]+\.[0-9]+(-(rc|dev)[0-9]+)?'

ga_release_label_valid() { [[ "${1:-}" =~ ^${GA_RELEASE_LABEL_RE}$ ]]; }

# ga_pretty_name LABEL OSVER -> GreenAutarky <label> (HAOS <osver>)
ga_pretty_name() { printf 'GreenAutarky %s (HAOS %s)\n' "$1" "$2"; }

# ga_artifact_basename LABEL BOARD OSVER -> <label>_<board>_<osver>  (no extension)
ga_artifact_basename() {
	ga_release_label_valid "${1:-}" || { echo "ga_artifact_basename: bad ga_release '${1:-}'" >&2; return 1; }
	[[ "${2:-}" =~ ^[a-z0-9]+$ ]] || { echo "ga_artifact_basename: bad board '${2:-}'" >&2; return 1; }
	[[ "${3:-}" =~ ^[0-9]+(\.[0-9]+)+$ ]] || { echo "ga_artifact_basename: bad os version '${3:-}'" >&2; return 1; }
	printf '%s_%s_%s\n' "$1" "$2" "$3"
}

# ga_artifact_parse NAME -> "<label> <board> <osver>" for a name written by
# ga_artifact_basename (any directory, any extension incl. _provisioning).
# rc 1 for everything else (legacy bos_* names included).
ga_artifact_parse() {
	local n="${1##*/}"
	[[ "$n" =~ ^(${GA_RELEASE_LABEL_RE})_([a-z0-9]+)_([0-9]+(\.[0-9]+)+)(_provisioning)?\.(img\.xz|img|raucb)(\.sha256|\.meta\.json)?$ ]] || return 1
	# BASH_REMATCH: 1=label 2=(rc|dev)suffix-group 3=rc|dev 4=board 5=osver
	printf '%s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
}

# ga_stamp_release_label TARGET_DIR LABEL
# Rewrites PRETTY_NAME in the REAL os-release file (symlinks followed, never
# replaced - /etc/os-release is a symlink on HAOS and ga-rauc-install refuses a
# regular file there), and writes /etc/motd and /etc/issue. VERSION_ID is read
# from the same file, so the label can never disagree with the OS version.
# Fails (rc 1) on anything it cannot do - a silent skip would ship the old name.
ga_stamp_release_label() {
	local t="$1" label="$2" f osver pretty n=0
	ga_release_label_valid "$label" || { echo "ga_stamp_release_label: bad ga_release '$label'" >&2; return 1; }
	for f in "$t/usr/lib/os-release" "$t/etc/os-release"; do
		[ -e "$f" ] || continue
		osver="$(sed -n 's/^VERSION_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$f" | head -n 1)"
		[ -n "$osver" ] || { echo "ga_stamp_release_label: no VERSION_ID in $f" >&2; return 1; }
		pretty="$(ga_pretty_name "$label" "$osver")"
		sed -i --follow-symlinks '/^PRETTY_NAME=/d' "$f"
		printf 'PRETTY_NAME="%s"\n' "$pretty" >> "$f"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || { echo "ga_stamp_release_label: no os-release under $t" >&2; return 1; }
	mkdir -p "$t/etc"
	printf 'Welcome to \033[01;34m%s\033[00m.\n\nUse `ha` to access the Home Assistant CLI.\n' "$pretty" > "$t/etc/motd"
	printf '%s \\n \\l\n' "$pretty" > "$t/etc/issue"
}
