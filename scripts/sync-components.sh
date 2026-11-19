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
#   4 — a components_<board>: block cannot be placed (no / several board overlays,
#       or the same component pinned in the shared block AND a board block)
#   5 — the shared block read by yq differs from the one ga_build.sh reads
#
# Board blocks (components_<board>:, Odoo #2187) go ONLY into that board's own
# overlay, buildroot-<board>/board/<vendor>/<board>/rootfs-overlay/usr/share/ga/
# custom_components/, so no other board's image carries them. The block reader is
# scripts/lib/ga-components.sh, shared with ga_build.sh and the build tests.
#
# Test hook: GA_SYNC_FROM_DIR=<dir> takes <name>-<version>.tar.gz from <dir>
# instead of `oras pull` (tests/ga_tests/board_components); placement is unchanged.

set -euo pipefail

# Ensure /usr/local/bin is on PATH — oras + Go-yq are typically installed
# there but minimal LXC / container environments often don't include it
# in the default PATH for non-login shells. Idempotent.
case ":${PATH}:" in
  *:/usr/local/bin:*) ;;
  *) export PATH="/usr/local/bin:${PATH}" ;;
esac

REPO_ROOT="${GA_SYNC_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
VERSION_YAML="${REPO_ROOT}/version.yaml"
# shellcheck source=lib/tree-paths.sh
. "$(dirname "$0")/lib/tree-paths.sh"
# shellcheck source=lib/ga-components.sh
. "$(dirname "$0")/lib/ga-components.sh"
DEST_BASE="${REPO_ROOT}/buildroot-external/rootfs-overlay/usr/share/ga/custom_components"
GHCR_NAMESPACE="ghcr.io/greenautarky"

# --- preflight ---------------------------------------------------------

if [ -z "${GA_SYNC_FROM_DIR:-}" ] && ! command -v oras >/dev/null 2>&1; then
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

# Two readers of the same block (yq here, the awk reader in ga_build.sh's
# pre-flight): if they disagree, the build checks something other than what was
# synced. Compare instead of trusting either.
awk_list=$(ga_components_block "${VERSION_YAML}" components)
if [ "$(printf '%s\n' "${components_list}" | sort)" != "$(printf '%s\n' "${awk_list}" | sort)" ]; then
  echo "::error::the shared components: block reads differently with yq and with ga-components.sh:" >&2
  echo "  yq:  $(printf '%s' "${components_list}" | tr '\n' ';')" >&2
  echo "  awk: $(printf '%s' "${awk_list}" | tr '\n' ';')" >&2
  exit 5
fi

# fetch_artifact NAME VERSION DIR — the OCI artifact's files into DIR.
fetch_artifact() {
  if [ -n "${GA_SYNC_FROM_DIR:-}" ]; then
    cp "${GA_SYNC_FROM_DIR}/$1-$2.tar.gz" "$3/" 2>/dev/null
  else
    (cd "$3" && oras pull "${GHCR_NAMESPACE}/$1:$2" >/dev/null 2>&1)
  fi
}

if [ -z "${components_list}" ]; then
  echo "No shared components to sync (all pins are null in ${VERSION_YAML})."
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
  if ! fetch_artifact "${pkg_name}" "${pkg_version}" "${tmpdir}"; then
    echo "::error::oras pull failed for ${pkg_name}:${pkg_version}" >&2
    any_failed=1; continue
  fi

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

# --- board components (components_<board>:) -----------------------------

shared_names=" $(printf '%s\n' "${components_list}" | awk '{print $1}' | tr '\n' ' ') "
for board in $(ga_component_boards "${VERSION_YAML}"); do
  overlay=$(ga_board_overlay "${REPO_ROOT}" "${board}") || exit 4
  board_dest="${overlay}/usr/share/ga/custom_components"
  echo "Board components for ${board} -> ${board_dest}:"
  while read -r pkg_name pkg_version; do
    [ -z "${pkg_name}" ] && continue
    case "${shared_names}" in *" ${pkg_name} "*)
      echo "::error::${pkg_name} is pinned in components: AND components_${board}: — one or the other" >&2
      exit 4 ;;
    esac
    domain="${pkg_name//-/_}"
    dest_dir="${board_dest}/${domain}"
    marker="${dest_dir}/.synced-version"
    if [ -f "${marker}" ] && [ "$(cat "${marker}")" = "${pkg_version}" ]; then
      echo "  ${pkg_name}@${pkg_version} — already synced (skip)"
      continue
    fi
    tmpdir=$(mktemp -d)
    if ! fetch_artifact "${pkg_name}" "${pkg_version}" "${tmpdir}"; then
      echo "::error::oras pull failed for ${pkg_name}:${pkg_version}" >&2
      rm -rf "${tmpdir}"; exit 3
    fi
    tarball=$(find "${tmpdir}" -name "*.tar.gz" | head -1)
    if [ -z "${tarball}" ]; then
      echo "::error::no tarball in OCI artifact for ${pkg_name}:${pkg_version}" >&2
      rm -rf "${tmpdir}"; exit 3
    fi
    mkdir -p "${board_dest}"
    rm -rf "${dest_dir}"
    tar -xzf "${tarball}" -C "${board_dest}"
    rm -rf "${tmpdir}"
    if [ ! -f "${dest_dir}/manifest.json" ]; then
      echo "::error::${pkg_name}:${pkg_version} did not unpack to ${domain}/manifest.json" >&2
      exit 3
    fi
    echo "${pkg_version}" > "${marker}"
    echo "  ${pkg_name}@${pkg_version} — synced to ${dest_dir}"
  done <<EOB
$(ga_components_block "${VERSION_YAML}" "components_${board}")
EOB
done

# A board component left in the SHARED overlay (from a sync before it moved to a
# board block) would ship on every board. Generated content: remove it, loudly.
for domain in $(ga_board_component_domains "${VERSION_YAML}"); do
  if [ -e "${DEST_BASE}/${domain}" ]; then
    echo "::warning::removing ${DEST_BASE}/${domain}: it is a board component and must not be in the shared overlay" >&2
    rm -rf "${DEST_BASE:?}/${domain}"
  fi
done

# --- rootfs_overlays ---------------------------------------------------
#
# A second class of Tier-2 component: its tarball doesn't follow the
# HA-integration "<domain>/manifest.json" layout. Instead it ships
# rootfs-shaped paths (usr/sbin/foo, etc/systemd/system/foo.service,
# etc/systemd/system/multi-user.target.wants/foo.service symlink) and
# should extract straight into `buildroot-external/rootfs-overlay/`.
#
# Example: ga-bootstrap (the first-boot orchestrator).
#
# Detection is explicit via a separate `rootfs_overlays:` map in
# version.yaml — easier to read than auto-detecting the tarball shape,
# and lets a single component repo declare which kind it is.

OVERLAY_BASE="${REPO_ROOT}/buildroot-external/rootfs-overlay"
overlay_list=$(yq -r '.rootfs_overlays // {} | to_entries[] | select(.value != null) | "\(.key) \(.value)"' "${VERSION_YAML}")

if [ -n "${overlay_list}" ]; then
  echo
  echo "Syncing rootfs_overlays:"
  any_overlay_failed=0
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    pkg_name=$(echo "${line}" | awk '{print $1}')
    pkg_version=$(echo "${line}" | awk '{print $2}')

    # Marker file lives OUTSIDE the rootfs-overlay (= gitignored
    # `ga_output/.sync-markers/`). Putting it inside the overlay
    # would bake it into the device rootfs, where it'd then be hidden
    # by the tmpfs that the kernel mounts over `/tmp/` at boot — and
    # the rootfs is read-only anyway, so we couldn't update markers
    # in place. Keep them on the builder side; first build after a
    # fresh clone re-pulls (cheap, oras pull is ~1 s).
    marker_dir="${REPO_ROOT}/ga_output/.sync-markers"
    mkdir -p "${marker_dir}"
    marker="${marker_dir}/${pkg_name}.synced-version"

    if [ -f "${marker}" ] && [ "$(cat "${marker}")" = "${pkg_version}" ]; then
      echo "  ${pkg_name}@${pkg_version} — already synced (skip)"
      continue
    fi

    echo "  ${pkg_name}@${pkg_version} — pulling…"
    tmpdir=$(mktemp -d)
    (
      cd "${tmpdir}"
      if ! oras pull "${GHCR_NAMESPACE}/${pkg_name}:${pkg_version}" >/dev/null 2>&1; then
        echo "::error::oras pull failed for ${pkg_name}:${pkg_version}" >&2
        exit 1
      fi
    ) || { any_overlay_failed=1; rm -rf "${tmpdir}"; continue; }

    tarball=$(find "${tmpdir}" -name "*.tar.gz" | head -1)
    if [ -z "${tarball}" ]; then
      echo "::error::no tarball in OCI artifact for ${pkg_name}:${pkg_version}" >&2
      any_overlay_failed=1
      rm -rf "${tmpdir}"
      continue
    fi

    # NB: do NOT `rm -rf` the overlay base before extracting — other
    # components / hand-curated rootfs content live there. The tarball
    # is trusted to ship only the paths it owns; collisions overwrite,
    # which is the desired behaviour for a deliberate version bump.
    tar -xzf "${tarball}" -C "${OVERLAY_BASE}"
    rm -rf "${tmpdir}"

    echo "${pkg_version}" > "${marker}"
    echo "  ${pkg_name}@${pkg_version} — extracted into ${OVERLAY_BASE}"
  done <<< "${overlay_list}"

  if [ "${any_overlay_failed}" -ne 0 ]; then
    exit 3
  fi
fi

echo
echo "All pinned components synced."
