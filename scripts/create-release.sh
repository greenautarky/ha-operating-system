#!/bin/bash
# create-release.sh — Package all release artifacts into a single archive
#
# Run AFTER build + device tests + E2E tests are complete.
# Collects: OS image, RAUC bundle, reports, SBOMs, configs, legal-info,
#           test results, and generates a combined test report.
#
# Usage:
#   ./scripts/create-release.sh [options]
#
#   --build-dir PATH       Build output dir (default: ga_output)
#   --device-output PATH   Device test output (run_all.sh stdout)
#   --e2e-results PATH     Playwright JSON results
#   --device-ip IP         Device IP (for report metadata)
#   --output-dir PATH      Where to write the release archive (default: releases/)
#
# Output:
#   releases/bos_ihost_CoreBox-16.3_prod_YYYYMMDDHHMMSS_release.tar.gz
#
# Contents:
#   images/
#     *.img.xz + *.sha256          OS disk image
#     *.raucb + *.sha256           RAUC OTA bundle
#   reports/
#     build-report.html            Build report (versions, sizes, CVE, tests)
#     test-report.html             Combined test report (build + device + E2E)
#     cve-scan-sbom.txt            CVE scan — OS packages
#     cve-scan-containers.txt      CVE scan — container images
#   configs/
#     source-pins.json             Git SHAs of all source repos
#     container-images.lock.json   Container image digests
#     defconfig                    Buildroot defconfig
#   legal-info/
#     manifest.csv                 License manifest
#     host-manifest.csv            Host tool licenses
#     legal-info-full.tar.xz       Full source archive (GPL compliance)
#   sbom/
#     sbom-cyclonedx.json          CycloneDX 1.6 SBOM (OS packages)
#     sbom-containers.json         Container image inventory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-ga_output}"
DEVICE_OUTPUT=""
E2E_RESULTS=""
DEVICE_IP="${DEVICE_IP:-unknown}"
OUTPUT_DIR="${OUTPUT_DIR:-releases}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --build-dir)      BUILD_DIR="$2"; shift 2 ;;
    --device-output)  DEVICE_OUTPUT="$2"; shift 2 ;;
    --e2e-results)    E2E_RESULTS="$2"; shift 2 ;;
    --device-ip)      DEVICE_IP="$2"; shift 2 ;;
    --output-dir)     OUTPUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Find the latest image
IMG_XZ="$(ls "${BUILD_DIR}/images/"bos_*.img.xz 2>/dev/null | sort | tail -n 1 || true)"
if [[ -z "$IMG_XZ" ]]; then
  echo "ERROR: No bos_*.img.xz found in ${BUILD_DIR}/images/" >&2
  exit 1
fi

# Extract build ID from filename (bos_ihost_CoreBox-16.3_prod_20260331112238.img.xz)
IMG_BASE="$(basename "$IMG_XZ" .img.xz)"
BUILD_ID="$(echo "$IMG_BASE" | grep -oP '\d{14}$' || echo "unknown")"
echo "Release for: $IMG_BASE (build $BUILD_ID)"

# Create temp staging dir
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

mkdir -p "$STAGE_DIR/images" "$STAGE_DIR/reports" "$STAGE_DIR/configs" \
         "$STAGE_DIR/legal-info" "$STAGE_DIR/sbom"

# --- 1. Images ---
echo "[1/6] Collecting images..."
for ext in img.xz img.xz.sha256 raucb raucb.sha256; do
  f="${BUILD_DIR}/images/${IMG_BASE}.${ext}"
  [[ -f "$f" ]] && cp "$f" "$STAGE_DIR/images/"
done

# --- 2. Reports ---
echo "[2/6] Collecting reports..."
for f in build-report.html cve-scan-sbom.txt cve-scan-containers.txt; do
  [[ -f "${BUILD_DIR}/images/reports/$f" ]] && cp "${BUILD_DIR}/images/reports/$f" "$STAGE_DIR/reports/"
done

# Generate combined test report if test results are available
if [[ -n "$DEVICE_OUTPUT" ]] || [[ -n "$E2E_RESULTS" ]]; then
  echo "  Generating combined test report..."
  REPORT_ARGS=(
    --build-report "${BUILD_DIR}/images/reports/build-report.html"
    --output "$STAGE_DIR/reports/test-report.html"
    --build-id "$BUILD_ID"
    --device-ip "$DEVICE_IP"
  )
  [[ -n "$DEVICE_OUTPUT" ]] && REPORT_ARGS+=(--device-output "$DEVICE_OUTPUT")
  [[ -n "$E2E_RESULTS" ]] && REPORT_ARGS+=(--e2e-results "$E2E_RESULTS")
  "${SCRIPT_DIR}/../tests/generate-report.sh" "${REPORT_ARGS[@]}" || echo "  WARN: test report generation failed"
fi

# Generate changelog
echo "  Generating changelog..."
"${SCRIPT_DIR}/generate-changelog.sh" \
  --build-dir "$BUILD_DIR" \
  --output "$STAGE_DIR/CHANGELOG.md" 2>/dev/null || echo "  WARN: changelog generation failed"

# Copy Playwright HTML report if available
PW_REPORT="$(dirname "$SCRIPT_DIR")/tests/e2e/playwright-report"
if [[ -d "$PW_REPORT" ]]; then
  cp -r "$PW_REPORT" "$STAGE_DIR/reports/playwright-report"
fi

# --- 3. Configs ---
echo "[3/6] Collecting configs..."
for f in source-pins.json container-images.lock.json container-images.lock; do
  [[ -f "${BUILD_DIR}/images/configs/$f" ]] && cp "${BUILD_DIR}/images/configs/$f" "$STAGE_DIR/configs/"
done
# Copy defconfig
DEFCONFIG="${BUILD_DIR}/.config"
[[ -f "$DEFCONFIG" ]] && cp "$DEFCONFIG" "$STAGE_DIR/configs/defconfig"

# --- 4. Legal info ---
echo "[4/6] Collecting legal-info..."
for f in manifest.csv host-manifest.csv; do
  [[ -f "${BUILD_DIR}/images/legal-info/$f" ]] && cp "${BUILD_DIR}/images/legal-info/$f" "$STAGE_DIR/legal-info/"
done
# Include full source archive if present (large — ~500MB+)
LEGAL_TAR="${BUILD_DIR}/images/legal-info/legal-info-full.tar.xz"
if [[ -f "$LEGAL_TAR" ]]; then
  cp "$LEGAL_TAR" "$STAGE_DIR/legal-info/"
fi

# --- 5. SBOMs ---
echo "[5/6] Collecting SBOMs..."
[[ -f "${BUILD_DIR}/images/sbom-cyclonedx.json" ]] && cp "${BUILD_DIR}/images/sbom-cyclonedx.json" "$STAGE_DIR/sbom/"
[[ -f "${BUILD_DIR}/images/sbom-containers.json" ]] && cp "${BUILD_DIR}/images/sbom-containers.json" "$STAGE_DIR/sbom/"

# --- 6. Create archive ---
echo "[6/6] Creating release archive..."
mkdir -p "$OUTPUT_DIR"
RELEASE_FILE="${OUTPUT_DIR}/${IMG_BASE}_release.tar.gz"
tar -czf "$RELEASE_FILE" -C "$STAGE_DIR" .

RELEASE_SIZE="$(du -h "$RELEASE_FILE" | cut -f1)"
echo ""
echo "=================================================="
echo "  Release archive: $RELEASE_FILE"
echo "  Size: $RELEASE_SIZE"
echo "=================================================="
echo ""
echo "  Contents:"
tar -tzf "$RELEASE_FILE" | sed 's|^./||' | grep -v '/$' | sort | sed 's/^/    /'
echo ""

# Generate SHA256 for the release archive
sha256sum "$RELEASE_FILE" > "${RELEASE_FILE}.sha256"
echo "  SHA256: $(cat "${RELEASE_FILE}.sha256")"
