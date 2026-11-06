# shellcheck shell=bash
archive_build_configs() {
  local manifest="${cfg_dir}/MANIFEST.txt"
  { echo manifest; } > "$manifest"
  if "$_ev_script" "$OUT" "$_ev_ver" "${_ev_root}/${GA_BUILD_TIMESTAMP}"; then :; fi
  local container_lock="${cfg_dir}/container-images.lock"
}
