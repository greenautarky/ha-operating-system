# shellcheck shell=sh
GA_LAYER_DIR=layer
GA_VERSION_FILE=version.yaml
GA_BOARDS=""
GA_BOARD_DIR_ihost=board/ihost
GA_DEFCONFIG_ihost=board/ihost/configs/def
GA_ADDON_PINS_ihost=layer/pins.json
ga_board_var() { _v="$(eval "printf '%s' \"\${GA_$1_$2:-}\"")"; [ -n "$_v" ] || return 1; printf '%s\n' "$_v"; }
ga_tree_paths() {
	printf '%s %s\n' GA_LAYER_DIR "$GA_LAYER_DIR"
	printf '%s %s\n' GA_VERSION_FILE "$GA_VERSION_FILE"
	for _b in $GA_BOARDS; do
		for _k in BOARD_DIR DEFCONFIG ADDON_PINS; do
			_p="$(ga_board_var "$_k" "$_b")" || _p="<undefined>"
			printf '%s %s\n' "GA_${_k}_${_b}" "$_p"
		done
	done
}
