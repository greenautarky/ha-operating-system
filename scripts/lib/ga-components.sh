# shellcheck shell=sh
# ga-components.sh — the ONE reader of the version.yaml component blocks.
#
#   components:            shared, staged on every board (buildroot-external overlay)
#   components_<board>:    only for <board>, staged into that board's own overlay,
#                          $GA_BOARD_BASE_<board>/rootfs-overlay (scripts/lib/tree-paths.sh;
#                          the overlay the board's defconfig lists in BR2_ROOTFS_OVERLAY)
#
# Used by scripts/sync-components.sh (board blocks), scripts/ga_build.sh (pre-flight)
# and tests/ga_tests/run_build_tests.sh (image check), so the three cannot disagree
# about what a block contains. POSIX sh + awk only: the build container has no yq.
# A board component is a component the OTHER boards must not carry (Odoo #2187:
# ga_dsgw_ble declares the `bluetooth` dependency; on the iHost that would start HA's
# own Bluetooth integration).

# The board map is tree-paths.sh, not a second copy of it: source it BEFORE this file.
if ! command -v ga_board_var >/dev/null 2>&1 || [ -z "${GA_LAYER_DIR:-}" ]; then
  echo "ga-components.sh: source scripts/lib/tree-paths.sh first" >&2
  return 1 2>/dev/null || exit 1
fi

# ga_shared_components_dir REPO — where shared components are staged.
ga_shared_components_dir() { echo "$1/${GA_LAYER_DIR:?tree-paths.sh not loaded}/rootfs-overlay/usr/share/ga/custom_components"; }

# ga_components_block FILE KEY — "name version" per pinned entry of the top-level
# mapping KEY. Null / empty / "~" pins are skipped (= not ready for OCI pull).
ga_components_block() {
  awk -v key="$2" '
    /^[^[:space:]#][^:]*:/ { blk = (index($0, key ":") == 1); next }
    blk && /^  [a-z0-9][a-z0-9_-]*:/ {
      name = $1; sub(/:$/, "", name)
      v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); sub(/[[:space:]]*#.*$/, "", v)
      gsub(/"/, "", v); gsub(/[[:space:]]/, "", v)
      if (v != "" && v != "null" && v != "~") print name, v
    }' "$1"
}

# ga_component_boards FILE — the <board> of every components_<board>: block.
ga_component_boards() {
  awk '/^components_[a-z0-9]+:/ { b = $1; sub(/^components_/, "", b); sub(/:$/, "", b); print b }' "$1"
}

# ga_board_overlay REPO BOARD — that board's own rootfs overlay, from the board map.
# Non-zero when the board is not in the map or has no overlay directory: a board
# block that cannot be placed must never fall back to the shared overlay.
ga_board_overlay() {
  if ! _gbo_base=$(ga_board_var BOARD_BASE "$2"); then
    echo "ga_board_overlay: board '$2' is not in scripts/lib/tree-paths.sh (GA_BOARDS)" >&2
    return 1
  fi
  if [ ! -d "$1/$_gbo_base/rootfs-overlay" ]; then
    echo "ga_board_overlay: board '$2' has no own rootfs overlay ($1/$_gbo_base/rootfs-overlay)" >&2
    return 1
  fi
  echo "$1/$_gbo_base/rootfs-overlay"
}

# ga_board_component_domains FILE — the domain (dash -> underscore) of every
# component in ANY board block, one per line, sorted, unique.
ga_board_component_domains() {
  for _gbd_b in $(ga_component_boards "$1"); do
    ga_components_block "$1" "components_${_gbd_b}" | while read -r _gbd_n _gbd_v; do
      echo "$_gbd_n" | tr '-' '_'
    done
  done | sort -u
}

# _gc_manifest_version DIR — "version" of DIR/manifest.json, empty when absent.
_gc_manifest_version() {
  grep -oE '"version":[[:space:]]*"[^"]*"' "$1/manifest.json" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)"$/\1/'
}

# ga_board_components_preflight REPO BOARD — run before building BOARD (ga_build.sh).
#   * no board component of ANY board sits in the shared overlay (it would ship on
#     every board);
#   * every components_<BOARD> pin is synced in BOARD's overlay at the pinned version.
# Prints one line per finding on stderr; non-zero when anything is wrong.
ga_board_components_preflight() {
  _bp_yaml="$1/version.yaml"; _bp_rc=0
  _bp_shared=$(ga_shared_components_dir "$1")
  for _bp_d in $(ga_board_component_domains "$_bp_yaml"); do
    if [ -e "$_bp_shared/$_bp_d" ]; then
      echo "FAIL: board component '$_bp_d' is in the SHARED overlay ($_bp_shared/$_bp_d): every board would ship it — run scripts/sync-components.sh" >&2
      _bp_rc=1
    fi
  done
  _bp_list=$(ga_components_block "$_bp_yaml" "components_$2")
  [ -n "$_bp_list" ] || return "$_bp_rc"
  _bp_ov=$(ga_board_overlay "$1" "$2") || return 1
  while read -r _bp_n _bp_v; do
    _bp_dir="$_bp_ov/usr/share/ga/custom_components/$(echo "$_bp_n" | tr '-' '_')"
    _bp_have=$(_gc_manifest_version "$_bp_dir")
    if [ -z "$_bp_have" ]; then
      echo "FAIL: board component '$_bp_n' pinned to $_bp_v for $2 but $_bp_dir is missing — run scripts/sync-components.sh" >&2; _bp_rc=1
    elif [ "$_bp_have" != "$_bp_v" ]; then
      echo "FAIL: board component '$_bp_n' manifest says $_bp_have but components_$2 pins $_bp_v — run scripts/sync-components.sh" >&2; _bp_rc=1
    else
      echo "Board component check ($2): $_bp_n@$_bp_v ✓"
    fi
  done <<EOB
$_bp_list
EOB
  return "$_bp_rc"
}

# ga_board_components_image_check YAML TARGET BOARD — on the BUILT rootfs:
#   BCI-01 every components_<BOARD> pin is in TARGET at the pinned version;
#   BCI-02 no component pinned for ANOTHER board is in TARGET.
# Prints PASS/FAIL lines on stdout; non-zero on any FAIL.
ga_board_components_image_check() {
  _bi_cc="$2/usr/share/ga/custom_components"; _bi_rc=0; _bi_n=0
  while read -r _bi_name _bi_v; do
    [ -n "$_bi_name" ] || continue
    _bi_n=$((_bi_n + 1)); _bi_d=$(echo "$_bi_name" | tr '-' '_')
    _bi_have=$(_gc_manifest_version "$_bi_cc/$_bi_d")
    if [ "$_bi_have" = "$_bi_v" ]; then echo "PASS BCI-01 $3 image carries $_bi_d@$_bi_v"
    else echo "FAIL BCI-01 $3 image: $_bi_d pinned $_bi_v, image has '${_bi_have:-nothing}'"; _bi_rc=1; fi
  done <<EOB
$(ga_components_block "$1" "components_$3")
EOB
  for _bi_b in $(ga_component_boards "$1"); do
    [ "$_bi_b" = "$3" ] && continue
    for _bi_d in $(ga_components_block "$1" "components_${_bi_b}" | awk '{print $1}' | tr '-' '_'); do
      _bi_n=$((_bi_n + 1))
      if [ -e "$_bi_cc/$_bi_d" ]; then echo "FAIL BCI-02 $3 image carries $_bi_d, which is pinned for $_bi_b only"; _bi_rc=1
      else echo "PASS BCI-02 $3 image does not carry $_bi_d ($_bi_b only)"; fi
    done
  done
  [ "$_bi_n" -gt 0 ] || echo "PASS BCI-00 no board components declared (nothing to check)"
  return "$_bi_rc"
}
