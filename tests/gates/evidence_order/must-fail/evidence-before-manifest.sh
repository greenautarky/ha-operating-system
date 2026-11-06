# shellcheck shell=bash
archive_build_configs() {
  local cfg_dir="${OUT}/images/configs"
  local _ev_script="${SCRIPT_DIR}/ops/collect-release-evidence.sh"
  if "$_ev_script" "$OUT" "$_ev_ver" "${_ev_root}/${GA_BUILD_TIMESTAMP}"; then :; fi
  local manifest="${cfg_dir}/MANIFEST.txt"
  { echo manifest; } > "$manifest"
  local container_lock="${cfg_dir}/container-images.lock"
}
