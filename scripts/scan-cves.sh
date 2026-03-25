#!/usr/bin/env bash
# scan-cves.sh — Scan GA OS components for known vulnerabilities
#
# Usage:
#   ./scripts/scan-cves.sh                    # scan all
#   ./scripts/scan-cves.sh --images           # container images only
#   ./scripts/scan-cves.sh --sbom             # SBOM only (after prod build)
#   ./scripts/scan-cves.sh --severity HIGH    # filter by min severity
#
# Requires: trivy (https://aquasecurity.github.io/trivy/)
#   Install: curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
SCAN_IMAGES=true
SCAN_SBOM=true
SEVERITY="${SEVERITY:-CRITICAL,HIGH}"
OUTPUT_DIR="${REPO_ROOT}/scan-results"
EXIT_CODE=0

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --images)  SCAN_SBOM=false;  shift ;;
    --sbom)    SCAN_IMAGES=false; shift ;;
    --severity) SEVERITY="$2";   shift 2 ;;
    --help|-h)
      head -11 "$0" | tail -9
      exit 0
      ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Check trivy
if ! command -v trivy &>/dev/null; then
  echo "ERROR: trivy not found. Install with:"
  echo "  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
echo "=== GA OS CVE Scan ==="
echo "  Date:     $(date -Iseconds)"
echo "  Severity: ${SEVERITY}"
echo ""

# --- Container image scanning ---
if [[ "$SCAN_IMAGES" == "true" ]]; then
  echo "=== Scanning Container Images ==="

  # Read images from version.json and addon-images.json
  VERSION_JSON="${REPO_ROOT}/buildroot-external/package/hassio/version.json"
  ADDON_JSON="${REPO_ROOT}/buildroot-external/package/hassio/addon-images.json"

  IMAGES=()

  if [[ -f "$VERSION_JSON" ]]; then
    # Core image
    CORE_IMG=$(jq -r '.images.core // empty' "$VERSION_JSON" 2>/dev/null || true)
    CORE_VER=$(jq -r '.versions.core // empty' "$VERSION_JSON" 2>/dev/null || true)
    [[ -n "$CORE_IMG" && -n "$CORE_VER" ]] && IMAGES+=("${CORE_IMG}:${CORE_VER}")

    # Supervisor
    SUP_IMG=$(jq -r '.images.supervisor // empty' "$VERSION_JSON" 2>/dev/null || true)
    SUP_VER=$(jq -r '.versions.supervisor // empty' "$VERSION_JSON" 2>/dev/null || true)
    [[ -n "$SUP_IMG" && -n "$SUP_VER" ]] && IMAGES+=("${SUP_IMG}:${SUP_VER}")
  fi

  if [[ -f "$ADDON_JSON" ]]; then
    while IFS= read -r img; do
      IMAGES+=("$img")
    done < <(jq -r '.[] | "\(.image):\(.version)"' "$ADDON_JSON" 2>/dev/null || true)
  fi

  TOTAL=${#IMAGES[@]}
  PASS=0
  FAIL=0

  for img in "${IMAGES[@]}"; do
    echo ""
    echo "--- Scanning: ${img} ---"
    REPORT="${OUTPUT_DIR}/image-$(echo "$img" | tr '/:' '__').json"

    if trivy image --severity "$SEVERITY" --format json --output "$REPORT" "$img" 2>/dev/null; then
      VULN_COUNT=$(jq '[.Results[]?.Vulnerabilities // [] | length] | add // 0' "$REPORT" 2>/dev/null || echo 0)
      if [[ "$VULN_COUNT" -gt 0 ]]; then
        echo "  FOUND: ${VULN_COUNT} vulnerabilities (${SEVERITY})"
        trivy image --severity "$SEVERITY" --format table "$img" 2>/dev/null || true
        FAIL=$((FAIL + 1))
      else
        echo "  CLEAN: no ${SEVERITY} vulnerabilities"
        PASS=$((PASS + 1))
      fi
    else
      echo "  SKIP: could not scan (image not pullable?)"
    fi
  done

  echo ""
  echo "=== Image Scan Summary: ${PASS} clean, ${FAIL} with findings (${TOTAL} total) ==="
  [[ "$FAIL" -gt 0 ]] && EXIT_CODE=1
fi

# --- SBOM scanning ---
if [[ "$SCAN_SBOM" == "true" ]]; then
  echo ""
  echo "=== Scanning SBOM ==="

  SBOM="${REPO_ROOT}/ga_output/images/sbom-cyclonedx.json"
  if [[ -f "$SBOM" ]]; then
    REPORT="${OUTPUT_DIR}/sbom-scan.json"
    echo "  SBOM: ${SBOM}"

    if trivy sbom --severity "$SEVERITY" --format json --output "$REPORT" "$SBOM" 2>/dev/null; then
      VULN_COUNT=$(jq '[.Results[]?.Vulnerabilities // [] | length] | add // 0' "$REPORT" 2>/dev/null || echo 0)
      if [[ "$VULN_COUNT" -gt 0 ]]; then
        echo "  FOUND: ${VULN_COUNT} vulnerabilities (${SEVERITY})"
        trivy sbom --severity "$SEVERITY" --format table "$SBOM" 2>/dev/null || true
        EXIT_CODE=1
      else
        echo "  CLEAN: no ${SEVERITY} vulnerabilities in OS packages"
      fi
    else
      echo "  ERROR: trivy sbom scan failed"
      EXIT_CODE=1
    fi
  else
    echo "  SKIP: no SBOM found (run a prod build first: ./scripts/ga_build.sh prod)"
  fi
fi

echo ""
echo "=== Scan Complete ==="
echo "  Results saved to: ${OUTPUT_DIR}/"
echo "  Exit code: ${EXIT_CODE}"
exit $EXIT_CODE
