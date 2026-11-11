# shellcheck shell=bash
# After generate_sbom but before assert_prod_sbom: a failed/empty SBOM would still be filed.
archive_build_configs() {
  local manifest="${cfg_dir}/MANIFEST.txt"
  { echo manifest; } > "$manifest"
  local container_lock="${cfg_dir}/container-images.lock"
}
generate_sbom() {
  local containers_file="${OUT}/images/sbom-containers.json"
}
collect_build_evidence() {
  if "$_ev_script" "$OUT" "$_ev_ver" "${_ev_root}/${GA_BUILD_TIMESTAMP}"; then :; fi
}
assert_prod_sbom() { :; }
archive_legal_info() { :; }
archive_build_configs
archive_legal_info
generate_sbom 2>&1 | tee -a "$BUILD_LOG"
collect_build_evidence
assert_prod_sbom "$_sbom_rc"
