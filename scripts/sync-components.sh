#!/usr/bin/env bash
# sync-components.sh — pull Tier-2 components from GHCR into the rootfs.
#
# Reads pinned versions from version.yaml at the repo root, and for each
# non-null component:
#   1. oras pull ghcr.io/greenautarky/<name>:<version>
#   2. extract the tarball
#   3. lay it out under buildroot-external/rootfs-overlay/usr/share/ga/
#      custom_components/<component_domain>/
#
# Idempotent: if the on-disk version matches the pin, skips the pull.
# The marker file `.synced-version` inside the component dir records
# what's currently there.
#
# Run by ga_build.sh before the rootfs is packaged. Can also be run
# manually for a quick sync without a full build:
#   ./scripts/sync-components.sh
#
# Exit codes:
#   0 — all pinned components synced (or skipped — already up-to-date)
#   1 — oras not on PATH or yq missing
#   2 — version.yaml malformed
#   3 — oras pull failed for at least one component

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_YAML="${REPO_ROOT}/version.yaml"
DEST_BASE="${REPO_ROOT}/buildroot-external/rootfs-overlay/usr/share/ga/custom_components"
GHCR_NAMESPACE="ghcr.io/greenautarky"

# --- preflight ---------------------------------------------------------

if ! command -v oras >/dev/null 2>&1; then
  echo "::error::oras is not on PATH — install it from https://oras.land/" >&2
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "::error::yq is not on PATH — install it (e.g. apt install yq)" >&2
  exit 1
fi

if [ ! -f "${VERSION_YAML}" ]; then
  echo "::error::${VERSION_YAML} not found — cannot determine component pins" >&2
  exit 2
fi

mkdir -p "${DEST_BASE}"

# --- iterate components ------------------------------------------------

# yq returns each "name version" pair on its own line; we filter out
# nulls (= components not yet ready for OCI pull).
components_list=$(yq -r '.components | to_entries[] | select(.value != null) | "\(.key) \(.value)"' "${VERSION_YAML}")

if [ -z "${components_list}" ]; then
  echo "No components to sync (all pins are null in ${VERSION_YAML})."
  exit 0
fi

any_failed=0

while IFS= read -r line; do
  [ -z "${line}" ] && continue
  pkg_name=$(echo "${line}" | awk '{print $1}')
  pkg_version=$(echo "${line}" | awk '{print $2}')

  # Component domain = pkg_name with dashes → underscores. The OCI tarball
  # we pull has the integration directory at its root using the underscore
  # form (matches HA's domain == directory convention).
  domain="${pkg_name//-/_}"
  dest_dir="${DEST_BASE}/${domain}"
  marker="${dest_dir}/.synced-version"

  if [ -f "${marker}" ] && [ "$(cat "${marker}")" = "${pkg_version}" ]; then
    echo "  ${pkg_name}@${pkg_version} — already synced (skip)"
    continue
  fi

  echo "  ${pkg_name}@${pkg_version} — pulling…"
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir}"' RETURN
  (
    cd "${tmpdir}"
    if ! oras pull "${GHCR_NAMESPACE}/${pkg_name}:${pkg_version}" >/dev/null 2>&1; then
      echo "::error::oras pull failed for ${pkg_name}:${pkg_version}" >&2
      exit 1
    fi
  ) || { any_failed=1; continue; }

  # Find + extract the tarball. oras leaves one or more files in tmpdir.
  tarball=$(find "${tmpdir}" -name "*.tar.gz" | head -1)
  if [ -z "${tarball}" ]; then
    echo "::error::no tarball in OCI artifact for ${pkg_name}:${pkg_version}" >&2
    any_failed=1
    continue
  fi

  # Clean out the old dir before extracting (in case a file got renamed
  # between versions; leftover files would be silent dead code).
  rm -rf "${dest_dir}"
  mkdir -p "${dest_dir}"
  tar -xzf "${tarball}" -C "${DEST_BASE}" --strip-components=0

  # Sanity: the extracted dir's manifest.json domain matches what we expect.
  manifest_json="${dest_dir}/manifest.json"
  if [ -f "${manifest_json}" ]; then
    domain_in_manifest=$(yq -r '.domain // ""' "${manifest_json}" 2>/dev/null || true)
    if [ -n "${domain_in_manifest}" ] && [ "${domain_in_manifest}" != "${domain}" ]; then
      echo "::warning::${pkg_name}: manifest domain '${domain_in_manifest}' != expected '${domain}'" >&2
    fi
  fi

  echo "${pkg_version}" > "${marker}"
  echo "  ${pkg_name}@${pkg_version} — synced to ${dest_dir}"
done <<< "${components_list}"

if [ "${any_failed}" -ne 0 ]; then
  exit 3
fi

echo
echo "All pinned components synced."
