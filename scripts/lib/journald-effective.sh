# shellcheck shell=bash
# journald-effective.sh — what journald will actually run with, read from the
# merged rootfs overlays (or a built target tree). Sourced, bash. No side
# effects on load.
#
# WHY THIS FILE EXISTS
#   On HAOS 18.x the GA layer does not own /etc/systemd/journald.conf (upstream
#   HAOS does, Storage=auto). GA settings live in journald.conf.d drop-ins, and
#   every board tree adds its own. journald reads the main file and then every
#   drop-in sorted by FILE NAME across /etc, /run, /usr/local/lib and /usr/lib
#   (same name: /etc wins); the last assignment wins. A check that greps one
#   file is green while a board drop-in that sorts later sets the value back
#   (`ihost.conf` sorts after `00-ga.conf`). Every check that judges a journald
#   setting asks this file instead.
#
#   ga_overlay_roots BOARD   one dir per line, in BR2_ROOTFS_OVERLAY order (later
#                            overlays overwrite earlier ones, as Buildroot copies
#                            them), read from the board's defconfig.
#   jd_effective KEY ROOT…   the effective [Journal] KEY over the merged ROOTs
#                            (empty = journald default). rc 1 when no main
#                            journald.conf exists in any ROOT.
#   ov_file REL ROOT…        the path REL resolves to in the merged ROOTs (last
#                            ROOT that has it); rc 1 when none has it.
#
# Paths come from scripts/lib/tree-paths.sh (source it first).

# ga_overlay_roots BOARD -> absolute overlay dirs, or rc 1 (never a partial list)
ga_overlay_roots() {
	local board="$1" root="${GA_REPO_ROOT:-.}" defc ext line v name d out=()
	defc="$(ga_board_var DEFCONFIG "$board")" || return 1
	defc="$root/$defc"
	[ -r "$defc" ] || return 1
	line="$(sed -n 's/^BR2_ROOTFS_OVERLAY="\(.*\)"$/\1/p' "$defc" | tail -1)"
	[ -n "$line" ] || return 1
	declare -A ext=()
	for d in "$root/$GA_HAOS_DIR/buildroot-external" "$root/$GA_LAYER_DIR"; do
		name="$(sed -n 's/^name:[[:space:]]*//p' "$d/external.desc" 2>/dev/null)"
		[ -n "$name" ] && ext[$name]="$d"
	done
	for b in $GA_BOARDS; do
		d="$root/$(ga_board_var BOARD_DIR "$b")" || continue
		name="$(sed -n 's/^name:[[:space:]]*//p' "$d/external.desc" 2>/dev/null)"
		[ -n "$name" ] && ext[$name]="$d"
	done
	for v in $line; do
		while [[ "$v" =~ \$\(BR2_EXTERNAL_([A-Z0-9_]+)_PATH\) ]]; do
			name="${BASH_REMATCH[1]}"
			[ -n "${ext[$name]:-}" ] || return 1
			v="${v//"${BASH_REMATCH[0]}"/${ext[$name]}}"
		done
		case "$v" in *'$('*) return 1 ;; esac
		[ -d "$v" ] || return 1
		out+=("$(cd "$v" && pwd)")
	done
	[ "${#out[@]}" -gt 0 ] || return 1
	printf '%s\n' "${out[@]}"
}

ov_file() {
	local rel="$1" r hit=""; shift
	for r in "$@"; do
		{ [ -e "$r/$rel" ] || [ -L "$r/$rel" ]; } && hit="$r/$rel"
	done
	[ -n "$hit" ] || return 1
	printf '%s\n' "$hit"
}

# jd_files ROOT… -> the files journald parses, in parse order
jd_files() {
	local main="" r rel f n dir
	main="$(ov_file etc/systemd/journald.conf "$@")" \
		|| main="$(ov_file usr/lib/systemd/journald.conf "$@")" || return 1
	printf '%s\n' "$main"
	declare -A drop=()
	# lowest priority first, so a same-named /etc drop-in replaces /usr/lib's
	for dir in usr/lib/systemd/journald.conf.d usr/local/lib/systemd/journald.conf.d \
	           run/systemd/journald.conf.d etc/systemd/journald.conf.d; do
		for r in "$@"; do
			for f in "$r/$dir"/*.conf; do
				{ [ -f "$f" ] || [ -L "$f" ]; } || continue
				n="$(basename "$f")"
				drop[$n]="$f"
			done
		done
	done
	for n in $(printf '%s\n' "${!drop[@]}" | LC_ALL=C sort); do
		printf '%s\n' "${drop[$n]}"
	done
}

jd_effective() {
	local key="$1" files f val="" found=""; shift
	files="$(jd_files "$@")" || return 1
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$f" 2>/dev/null; then
			val="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$f" | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
			found=1
		fi
	done <<<"$files"
	[ -n "$found" ] || val=""
	printf '%s\n' "$val"
}
