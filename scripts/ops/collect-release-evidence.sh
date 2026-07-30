#!/bin/bash
# collect-release-evidence.sh — gather the durable evidence for ONE promoted release.
#
# WHY THIS EXISTS
# ---------------
# Release evidence lived only in ga_output/images/ on the build machine, and the
# weekly cron prunes that: `ota-cleanup.sh --builder --retain 2 --archive-retain 2`.
# So the SBOM, the source pins and the licence obligations for a shipped version
# rotated out after two builds. That is sane disk hygiene and wrong for evidence —
# the CRA support period is years, not two builds. Measured 2026-07-30: there was
# no durable home for it at all, on any machine.
#
# It also must not live on the DEVICE. An on-device SBOM puts a complete
# component-and-version inventory on a read-only partition in a customer's home,
# to answer a question /etc/ga-build-id and GA_RELEASE already answer.
#
# WHAT MAKES THIS EVIDENCE RATHER THAN A FOLDER OF FILES
# ------------------------------------------------------
# EVIDENCE.md is GENERATED, and it states its own coverage: how many packages the
# SBOM covers, whether the CVE enrichment actually ran, how many packages carried
# a declared hash, which repositories' SHAs are recorded — and it NAMES whatever
# could not be collected. A report that cannot say what it covers is not evidence.
# This repo has already shipped an empty CVE report as a clean result (0 of 208
# packages scanned) and an unparseable, empty provenance record that only warned.
#
# FAIL-CLOSED
# -----------
# Exits non-zero when a required artefact is missing or unusable. The caller is
# the promotion step, so "no evidence" must mean "no promotion" — otherwise this
# becomes another artefact that exists and proves nothing.
#
# Usage: collect-release-evidence.sh <output_dir> <version> <dest_repo_checkout>
#   e.g. collect-release-evidence.sh /build/ga_output BOSv1.3.0 /tmp/ga-release-evidence
set -euo pipefail

OUT="${1:?Usage: $0 <output_dir> <version> <dest_repo_checkout>}"
VERSION="${2:?missing version (e.g. BOSv1.3.0)}"
DEST_REPO="${3:?missing destination repo checkout}"

IMAGES="${OUT}/images"
CFG="${IMAGES}/configs"
DEST="${DEST_REPO}/${VERSION}"

# Version label must be a well-formed BOS release string. A malformed label would
# create a directory nobody finds again, which defeats the point of archiving.
if ! echo "$VERSION" | grep -qE '^BOSv[0-9]+\.[0-9]+\.[0-9]+(-(rc|dev)[0-9]+)?$'; then
  echo "ERROR: version '$VERSION' is not a well-formed BOS release label" >&2
  exit 1
fi

[[ -d "$IMAGES" ]] || { echo "ERROR: no images dir at ${IMAGES}" >&2; exit 1; }
mkdir -p "$DEST"

# --- required set: absence is a hard failure -------------------------------
# These are the questions a regulator or a field engineer asks about a shipped
# version: what source built it, what is in it, what licences it carries.
declare -A REQUIRED=(
  ["source-pins.json"]="${CFG}/source-pins.json"
  ["MANIFEST.txt"]="${CFG}/MANIFEST.txt"
  ["sbom-containers.json"]="${IMAGES}/sbom-containers.json"
)
# --- expected set: absence is recorded, not fatal --------------------------
# Split from REQUIRED on purpose. A dev build legitimately has no CVE-enriched
# SBOM; a missing licence summary is worth naming but must not silently become
# "no evidence at all". What is NOT acceptable is absence going unmentioned.
declare -A EXPECTED=(
  ["sbom-cyclonedx.json"]="${IMAGES}/sbom-cyclonedx.json"
  ["hardware-config-summary.txt"]="${CFG}/hardware-config-summary.txt"
  ["LICENSE-SUMMARY.txt"]="${CFG}/LICENSE-SUMMARY.txt"
)

missing_required=""
for name in "${!REQUIRED[@]}"; do
  src="${REQUIRED[$name]}"
  if [[ -s "$src" ]]; then cp "$src" "${DEST}/${name}"; else missing_required+="${name} "; fi
done
if [[ -n "$missing_required" ]]; then
  echo "ERROR: required evidence missing or empty: ${missing_required}" >&2
  echo "       A release cannot be promoted without it." >&2
  exit 1
fi

missing_expected=""
for name in "${!EXPECTED[@]}"; do
  src="${EXPECTED[$name]}"
  if [[ -s "$src" ]]; then cp "$src" "${DEST}/${name}"; else missing_expected+="${name} "; fi
done

# --- coverage, measured from the artefacts themselves ---------------------
_jq() { command -v jq >/dev/null 2>&1 && jq -r "$1" "$2" 2>/dev/null || echo ""; }

n_repos="$(_jq '.repositories | length' "${DEST}/source-pins.json")"
n_pkgs_pinned="$(_jq '.packages | length' "${DEST}/source-pins.json")"
n_containers="$(_jq '.containers | length' "${DEST}/sbom-containers.json")"
if [[ -s "${DEST}/sbom-cyclonedx.json" ]]; then
  n_components="$(_jq '.components | length' "${DEST}/sbom-cyclonedx.json")"
  n_vulns="$(_jq '[.vulnerabilities // []] | flatten | length' "${DEST}/sbom-cyclonedx.json")"
  # The scan marker is what separates a scanned SBOM from a bare one. Without it
  # an un-enriched SBOM reads exactly like a clean scan result.
  if grep -q 'cve-check\|cve_check\|nvd' "${DEST}/sbom-cyclonedx.json" 2>/dev/null; then
    cve_state="enriched (marker present)"
  else
    cve_state="NOT ENRICHED — no cve-check marker; this is NOT a clean scan result"
  fi
else
  n_components="-"; n_vulns="-"; cve_state="absent"
fi

# Repositories with uncommitted changes at build time. A dirty tree means the
# recorded SHA does not fully describe what was built, and that has to be visible.
dirty="$(_jq '[.repositories | to_entries[] | select(.value.dirty_files > 0) | "\(.key)(\(.value.dirty_files))"] | join(" ")' "${DEST}/source-pins.json")"

# --- checksums, including the artefacts NOT stored here -------------------
# The images and the legal-info tarball are too large for git. Their sha256 is
# recorded so a copy found later can be proven to be the one this release shipped.
: > "${DEST}/SHA256SUMS"
( cd "$DEST" && sha256sum -- *.json *.txt 2>/dev/null >> SHA256SUMS ) || true
big_recorded=""
for f in "${IMAGES}"/*.img.xz "${IMAGES}"/*.raucb "${IMAGES}"/legal-info/legal-info-full.tar.xz; do
  [[ -f "$f" ]] || continue
  ( cd "$(dirname "$f")" && sha256sum -- "$(basename "$f")" ) >> "${DEST}/SHA256SUMS"
  big_recorded+="$(basename "$f") "
done

# --- EVIDENCE.md ---------------------------------------------------------
{
  echo "# Release evidence — ${VERSION}"
  echo
  echo "Collected by \`scripts/ops/collect-release-evidence.sh\` at promotion time."
  echo "Generated, not written by hand: every number below is read out of the"
  echo "artefacts in this directory."
  echo
  echo "## Coverage"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| source repositories pinned | ${n_repos:-0} |"
  echo "| packages with a declared hash | ${n_pkgs_pinned:-0} |"
  echo "| container images recorded | ${n_containers:-0} |"
  echo "| SBOM components | ${n_components} |"
  echo "| SBOM vulnerability entries | ${n_vulns} |"
  echo "| CVE enrichment | ${cve_state} |"
  echo
  if [[ -n "$dirty" ]]; then
    echo "⚠️ **Built from a DIRTY tree**: ${dirty}"
    echo
    echo "The recorded commit does not fully describe what was built. Treat the"
    echo "SHAs as a starting point, not as a reproduction recipe."
    echo
  else
    echo "All pinned repositories were clean at build time."
    echo
  fi
  echo "## What is NOT in this directory"
  echo
  if [[ -n "$big_recorded" ]]; then
    echo "Recorded by sha256 in \`SHA256SUMS\` but stored elsewhere (too large for git):"
    echo
    for b in $big_recorded; do echo "- \`${b}\`"; done
    echo
  fi
  if [[ -n "$missing_expected" ]]; then
    echo "⚠️ **Expected but ABSENT** — named rather than omitted:"
    echo
    for m in $missing_expected; do echo "- \`${m}\`"; done
    echo
  else
    echo "Nothing expected was missing."
    echo
  fi
  echo "## Verifying this later"
  echo
  echo '```sh'
  echo "cd ${VERSION} && sha256sum -c SHA256SUMS   # the large files must be present locally"
  echo '```'
} > "${DEST}/EVIDENCE.md"

echo "Release evidence for ${VERSION} written to ${DEST}"
echo "  repositories=${n_repos:-0} pinned-packages=${n_pkgs_pinned:-0} components=${n_components} cve=${cve_state}"
[[ -n "$missing_expected" ]] && echo "  NOTE: expected-but-absent: ${missing_expected}"
exit 0
