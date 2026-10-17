# shellcheck shell=sh
# tree-paths.sh — the ONE place that names where the GA layer and the boards live.
# Sourced, POSIX sh. No side effects on load. Paths are relative to the repo root.
#
# WHY THIS FILE EXISTS
#   The tree layout is about to move (HAOS 18.x lift, second board). Today 75
#   files under tests/ scripts/ .github/ spell `buildroot-external` out by hand;
#   a gate that points at a directory that no longer exists does not fail, it
#   inspects nothing and reports green. Every gate and script that needs a
#   layer, board, defconfig or pin-file path takes it from here, so a layout
#   change is one edit plus the check below turning red where a path is stale.
#
#   scripts/check-tree-paths.sh holds this map to reality (every path must
#   exist, a gate must inspect >0 files, CI path filters must cover the map).
#   Its fixtures are tests/gates/tree_paths/ (run in CI by lint.yml).
#
# ADDING A BOARD: append to GA_BOARDS and add the three GA_BOARD_DIR_/
#   GA_DEFCONFIG_/GA_ADDON_PINS_ variables for it; ga_tree_paths lists them.

GA_LAYER_DIR=buildroot-external
GA_VERSION_FILE=version.yaml
# Upstream Home Assistant OS, unmodified, as a git submodule (HAOS 18.x). Its
# working tree changes only through the patches scripts/apply-haos-patches.sh
# applies: GA_HAOS_PATCH_DIR, then GA_LAYER_DIR/patches-haos.
GA_HAOS_DIR=haos
GA_HAOS_PATCH_DIR=patches/haos
GA_BOARDS="ihost"

GA_BOARD_DIR_ihost=buildroot-ihost
GA_DEFCONFIG_ihost=buildroot-ihost/configs/ga_ihost_full_defconfig
GA_ADDON_PINS_ihost=buildroot-external/package/hassio/addon-images.json

# ga_board_var KIND BOARD — print the value of GA_<KIND>_<BOARD> (KIND: BOARD_DIR,
# DEFCONFIG, ADDON_PINS). Prints nothing and returns 1 when it is not defined,
# so a typo cannot silently yield an empty path.
ga_board_var() {
	_v="$(eval "printf '%s' \"\${GA_$1_$2:-}\"")"
	[ -n "$_v" ] || return 1
	printf '%s\n' "$_v"
}

# ga_tree_paths — one "NAME PATH" line per mapped path (the audit's work list).
ga_tree_paths() {
	printf '%s %s\n' GA_LAYER_DIR "$GA_LAYER_DIR"
	printf '%s %s\n' GA_VERSION_FILE "$GA_VERSION_FILE"
	[ -z "${GA_HAOS_DIR:-}" ] || printf '%s %s\n' GA_HAOS_DIR "$GA_HAOS_DIR"
	[ -z "${GA_HAOS_PATCH_DIR:-}" ] || printf '%s %s\n' GA_HAOS_PATCH_DIR "$GA_HAOS_PATCH_DIR"
	for _b in $GA_BOARDS; do
		for _k in BOARD_DIR DEFCONFIG ADDON_PINS; do
			_p="$(ga_board_var "$_k" "$_b")" || _p="<undefined>"
			printf '%s %s\n' "GA_${_k}_${_b}" "$_p"
		done
	done
}
