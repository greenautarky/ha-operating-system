# shellcheck shell=bash
archive_build_configs() {
  local manifest="${cfg_dir}/MANIFEST.txt"
  { echo manifest; } > "$manifest"
  local container_lock="${cfg_dir}/container-images.lock"
  if "$_ev_script" "$OUT" "$_ev_ver" "${_ev_root}/${GA_BUILD_TIMESTAMP}"; then :; fi
  echo "=== Build configuration archive complete: ${cfg_dir} ==="
}
