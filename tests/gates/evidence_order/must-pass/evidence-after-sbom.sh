# shellcheck shell=bash
# Correct shape: collector in its own function, invoked after every generator and
# after the SBOM fail-closed assertion.
archive_build_configs() {
  local manifest="${cfg_dir}/MANIFEST.txt"
  { echo manifest; } > "$manifest"
  local container_lock="${cfg_dir}/container-images.lock"
}
generate_sbom() {
  local containers_file="${OUT}/images/sbom-containers.json"
}
collect_build_evidence() {
  local _ev_script="${SCRIPT_DIR}/ops/collect-release-evidence.sh"
  if "$_ev_script" "$OUT" "$_ev_ver" "${_ev_root}/${GA_BUILD_TIMESTAMP}"; then :; fi
}
assert_prod_sbom() { :; }
archive_legal_info() { :; }
archive_build_configs
archive_legal_info
generate_sbom 2>&1 | tee -a "$BUILD_LOG"
assert_prod_sbom "$_sbom_rc"
collect_build_evidence
log_build_step "Build integrity checks"
