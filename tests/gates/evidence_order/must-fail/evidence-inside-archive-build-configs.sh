# shellcheck shell=bash
# The shape that failed BOSv1.6.0-rc12 and BOSv1.5.4-rc1 (2026-11-11): the evidence
# call lives in archive_build_configs, which runs BEFORE generate_sbom writes
# sbom-containers.json.
archive_build_configs() {
  local manifest="${cfg_dir}/MANIFEST.txt"
  { echo manifest; } > "$manifest"
  local container_lock="${cfg_dir}/container-images.lock"
  local _ev_script="${SCRIPT_DIR}/ops/collect-release-evidence.sh"
  if "$_ev_script" "$OUT" "$_ev_ver" "${_ev_root}/${GA_BUILD_TIMESTAMP}"; then :; fi
}
generate_sbom() {
  local containers_file="${OUT}/images/sbom-containers.json"
}
assert_prod_sbom() { :; }
archive_legal_info() { :; }
archive_build_configs
archive_legal_info
generate_sbom 2>&1 | tee -a "$BUILD_LOG"
assert_prod_sbom "$_sbom_rc"
