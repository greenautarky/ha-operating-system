#!/usr/bin/env bash
# scan-cves.sh — Scan GA OS components for known vulnerabilities
#
# Usage:
#   ./scripts/scan-cves.sh                    # scan all
#   ./scripts/scan-cves.sh --images           # container images only
#   ./scripts/scan-cves.sh --sbom             # SBOM only (after prod build)
#   ./scripts/scan-cves.sh --severity HIGH    # filter by min severity
#   ./scripts/scan-cves.sh --strict           # findings over budget are fatal too
#
# Exit codes (distinct on purpose — see COVERAGE below):
#   0  clean, or findings within the allowlist budget
#   1  findings above the budget          (fatal only with --strict)
#   2  the scan itself is broken          (ALWAYS fatal, never suppressed)
#
# COVERAGE — why exit 2 exists:
#   Until 2026-07-28 this script reported "CLEAN: no CRITICAL/HIGH vulnerabilities
#   in OS packages" on every build while scanning exactly ZERO of the 208 OS
#   packages. Trivy has no matcher for `family="buildroot"` and our CycloneDX
#   components carry no `purl`, so it silently evaluated nothing and returned
#   success. An empty report is indistinguishable from a clean one.
#   A scanner that covers nothing is now a hard error (exit 2), not a pass —
#   the same fail-closed rule as the prod root password (#239).
#
# Requires: trivy (https://aquasecurity.github.io/trivy/)
#   Install: curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
#   Optional: grype — matches on CPE, which our SBOM does carry (130/208).
#             Preferred for the OS SBOM when present; see docs/CVE-HANDLING.md.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
SCAN_IMAGES=true
SCAN_SBOM=true
SEVERITY="${SEVERITY:-CRITICAL,HIGH}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/scan-results}"
# SBOM location — overridable so ga_build.sh can point at its own $OUT tree
GA_SBOM="${GA_SBOM:-${REPO_ROOT}/ga_output/images/sbom-cyclonedx.json}"
ALLOW_FILE="${ALLOW_FILE:-${REPO_ROOT}/.cve-allowlist}"
# Minimum share of SBOM components a scanner must actually evaluate before we
# believe its verdict. Below this the result is treated as "not scanned".
COVERAGE_MIN_PCT="${COVERAGE_MIN_PCT:-50}"
# prod builds gate by default; dev/test report only
STRICT=false
[[ "${GA_ENV:-dev}" == "prod" ]] && STRICT=true

EXIT_CODE=0
SCAN_BROKEN=false

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --images)   SCAN_SBOM=false;  shift ;;
    --sbom)     SCAN_IMAGES=false; shift ;;
    --severity) SEVERITY="$2";    shift 2 ;;
    --strict)   STRICT=true;      shift ;;
    --no-strict) STRICT=false;    shift ;;
    --help|-h)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# trivy is required for the container images and for the OS fallback path, but
# NOT for an SBOM already enriched by cve-check — that path reads CycloneDX
# directly. Check where it is actually needed rather than up front.
HAVE_TRIVY=true
command -v trivy &>/dev/null || HAVE_TRIVY=false
if [[ "$HAVE_TRIVY" == "false" && "$SCAN_IMAGES" == "true" ]]; then
  echo "ERROR: trivy not found — the container image scan cannot run. Install with:"
  echo "  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin"
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
echo "=== GA OS CVE Scan ==="
echo "  Date:     $(date -Iseconds)"
echo "  Severity: ${SEVERITY}"
echo "  Strict:   ${STRICT} (GA_ENV=${GA_ENV:-dev})"
echo ""

# -----------------------------------------------------------------------------
# Allowlist — accepted findings, each with an owner and an expiry date.
#
# Format (one per line, '#' comments and blank lines ignored):
#   CVE-2025-1234  owner-handle  2026-12-31  reason text
#
# An entry stops suppressing on its expiry date. That is deliberate: a gate
# without an allowlist gets switched off within two weeks, and an allowlist
# without expiry dates becomes permanent amnesia.
# -----------------------------------------------------------------------------
ALLOWED_CVES=()
allow_expired=0
load_allowlist() {
  [[ -f "$ALLOW_FILE" ]] || return 0
  local today; today="$(date +%Y-%m-%d)"
  local cve owner expiry
  while read -r cve owner expiry _; do
    [[ -z "${cve:-}" || "${cve:0:1}" == "#" ]] && continue
    if [[ ! "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      echo "  WARN: allowlist entry '${cve}' has no valid expiry date — ignoring it"
      continue
    fi
    if [[ "$expiry" < "$today" ]]; then
      echo "  WARN: allowlist entry ${cve} EXPIRED ${expiry} (owner: ${owner}) — no longer suppressed"
      allow_expired=$((allow_expired + 1))
      continue
    fi
    ALLOWED_CVES+=("$cve")
  done < "$ALLOW_FILE"
  [[ ${#ALLOWED_CVES[@]} -gt 0 ]] && echo "  Allowlist: ${#ALLOWED_CVES[@]} active entr(ies) from ${ALLOW_FILE}"
  return 0
}

# is_allowed <CVE-ID>
is_allowed() {
  local id="$1" a
  for a in ${ALLOWED_CVES[@]+"${ALLOWED_CVES[@]}"}; do
    [[ "$a" == "$id" ]] && return 0
  done
  return 1
}

# count_unsuppressed <trivy-json> -> prints "<total> <suppressed>"
count_unsuppressed() {
  local report="$1" total=0 suppressed=0 id
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if is_allowed "$id"; then suppressed=$((suppressed + 1)); else total=$((total + 1)); fi
  done < <(jq -r '[.Results[]?.Vulnerabilities // []] | flatten | .[].VulnerabilityID' "$report" 2>/dev/null || true)
  # Trailing newline is required: `read` returns non-zero at EOF, which under
  # `set -e` would abort the whole scan.
  printf '%s %s\n' "$total" "$suppressed"
}

load_allowlist
echo ""

# --- Container image scanning ---
IMG_TOTAL=0; IMG_PASS=0; IMG_FAIL=0; IMG_FINDINGS=0; IMG_SUPPRESSED=0
if [[ "$SCAN_IMAGES" == "true" ]]; then
  echo "=== Scanning Container Images ==="

  # Fetch stable.json from haos-version repo and read addon-images.json
  STABLE_URL="https://raw.githubusercontent.com/greenautarky/haos-version/main/stable.json"
  ADDON_JSON="${REPO_ROOT}/buildroot-external/package/hassio/addon-images.json"
  ARCH="armv7"
  MACHINE="tinker"

  echo "  Fetching stable.json..."
  STABLE=$(curl -sf "$STABLE_URL" 2>/dev/null || true)

  IMAGES=()

  if [[ -n "$STABLE" ]]; then
    # Core image: replace {machine} placeholder
    CORE_TMPL=$(echo "$STABLE" | jq -r '.images.core // empty')
    CORE_VER=$(echo "$STABLE" | jq -r ".homeassistant.${MACHINE} // .homeassistant.default // empty")
    CORE_IMG="${CORE_TMPL//\{machine\}/$MACHINE}"
    [[ -n "$CORE_IMG" && -n "$CORE_VER" ]] && IMAGES+=("${CORE_IMG}:${CORE_VER}")

    # Supervisor: replace {arch} placeholder
    SUP_TMPL=$(echo "$STABLE" | jq -r '.images.supervisor // empty')
    SUP_VER=$(echo "$STABLE" | jq -r '.supervisor // empty')
    SUP_IMG="${SUP_TMPL//\{arch\}/$ARCH}"
    [[ -n "$SUP_IMG" && -n "$SUP_VER" ]] && IMAGES+=("${SUP_IMG}:${SUP_VER}")

    # System images (cli, dns, audio, observer, multicast)
    for comp in cli dns audio observer multicast; do
      IMG_TMPL=$(echo "$STABLE" | jq -r ".images.${comp} // empty")
      COMP_VER=$(echo "$STABLE" | jq -r ".${comp} // empty")
      IMG="${IMG_TMPL//\{arch\}/$ARCH}"
      [[ -n "$IMG" && -n "$COMP_VER" ]] && IMAGES+=("${IMG}:${COMP_VER}")
    done
  else
    echo "  WARN: Could not fetch stable.json — skipping system images"
  fi

  # Addon images
  if [[ -f "$ADDON_JSON" ]]; then
    while IFS= read -r img; do
      # Replace {arch} placeholder
      img="${img//\{arch\}/$ARCH}"
      IMAGES+=("$img")
    done < <(jq -r '.addons | to_entries[] | "\(.value.image):\(.value.version)"' "$ADDON_JSON" 2>/dev/null || true)
  fi

  IMG_TOTAL=${#IMAGES[@]}
  img_unscannable=0

  for img in ${IMAGES[@]+"${IMAGES[@]}"}; do
    echo ""
    echo "--- Scanning: ${img} ---"
    REPORT="${OUTPUT_DIR}/image-$(echo "$img" | tr '/:' '__').json"

    if trivy image --severity "$SEVERITY" --format json --output "$REPORT" "$img" 2>/dev/null; then
      read -r _n _s < <(count_unsuppressed "$REPORT") || true
      IMG_FINDINGS=$((IMG_FINDINGS + _n))
      IMG_SUPPRESSED=$((IMG_SUPPRESSED + _s))
      if [[ "$_n" -gt 0 ]]; then
        echo "  FOUND: ${_n} vulnerabilities (${SEVERITY})$([[ "$_s" -gt 0 ]] && echo ", ${_s} allowlisted")"
        trivy image --severity "$SEVERITY" --format table "$img" 2>/dev/null || true
        IMG_FAIL=$((IMG_FAIL + 1))
      else
        echo "  CLEAN: no unsuppressed ${SEVERITY} vulnerabilities$([[ "$_s" -gt 0 ]] && echo " (${_s} allowlisted)")"
        IMG_PASS=$((IMG_PASS + 1))
      fi
    else
      echo "  SKIP: could not scan (image not pullable?)"
      img_unscannable=$((img_unscannable + 1))
    fi
  done

  echo ""
  echo "=== Image Scan Summary: ${IMG_PASS} clean, ${IMG_FAIL} with findings (${IMG_TOTAL} total, ${img_unscannable} unscannable) ==="
  [[ "$IMG_FINDINGS" -gt 0 ]] && EXIT_CODE=1

  # Every image failing to pull is a broken scan, not a clean one.
  if [[ "$IMG_TOTAL" -gt 0 && "$img_unscannable" -eq "$IMG_TOTAL" ]]; then
    echo "  ERROR: not a single image could be scanned — the image scan is BROKEN, not clean"
    SCAN_BROKEN=true
  fi
fi

# -----------------------------------------------------------------------------
# OS SBOM scanning
#
# The verdict is only believed if the scanner demonstrably evaluated the
# components. `--list-all-pkgs` makes trivy report every package it considered;
# comparing that against the SBOM component count is an exact coverage measure.
# -----------------------------------------------------------------------------
SBOM_COMPONENTS=0; SBOM_SCANNED=0; SBOM_COVERAGE=0; SBOM_FINDINGS=0; SBOM_SUPPRESSED=0
SBOM_STATUS="skipped"
if [[ "$SCAN_SBOM" == "true" ]]; then
  echo ""
  echo "=== Scanning SBOM (OS packages) ==="

  if [[ -f "$GA_SBOM" ]]; then
    REPORT="${OUTPUT_DIR}/sbom-scan.json"
    SCANLOG="${OUTPUT_DIR}/sbom-scan.log"
    echo "  SBOM: ${GA_SBOM}"

    SBOM_COMPONENTS=$(jq '[.components // []] | flatten | length' "$GA_SBOM" 2>/dev/null || echo 0)
    echo "  Components in SBOM: ${SBOM_COMPONENTS}"

    # -- Preferred path: a SBOM already enriched by Buildroot's cve-check ------
    # cve-check matches on `cpe` (which Buildroot emits) instead of `purl`
    # (which it does not), and writes CycloneDX `analysis.state` per finding.
    # The `ga:cve-check` marker distinguishes an enriched SBOM from a bare one —
    # a bare SBOM already carries some `vulnerabilities` (Buildroot's
    # _IGNORE_CVES), so the presence of that array alone proves nothing.
    _enriched=$(jq -r '[.metadata.properties // [] | .[] | select(.name=="ga:cve-check") | .value] | first // empty' \
                  "$GA_SBOM" 2>/dev/null || true)
    if [[ -n "$_enriched" ]]; then
      echo "  Enriched by cve-check at ${_enriched}"
      # Coverage = components cve-check can actually match on (cpe AND version).
      SBOM_SCANNED=$(jq '[.components // [] | .[] | select(.cpe != null and .version != null)] | length' \
                       "$GA_SBOM" 2>/dev/null || echo 0)
      [[ "$SBOM_COMPONENTS" -gt 0 ]] && SBOM_COVERAGE=$(( SBOM_SCANNED * 100 / SBOM_COMPONENTS ))
      echo "  Packages evaluated: ${SBOM_SCANNED}/${SBOM_COMPONENTS} (${SBOM_COVERAGE}%)"
      # Shipped (target) packages are the ones that matter — report them separately.
      _tgt_total=$(jq '[.components // [] | .[] | select((.properties // [] | map(select(.name=="BR_TYPE").value) | first) == "target")] | length' "$GA_SBOM" 2>/dev/null || echo 0)
      _tgt_cov=$(jq '[.components // [] | .[] | select((.properties // [] | map(select(.name=="BR_TYPE").value) | first) == "target") | select(.cpe != null and .version != null)] | length' "$GA_SBOM" 2>/dev/null || echo 0)
      [[ "${_tgt_total:-0}" -gt 0 ]] && echo "  ...of which shipped (BR_TYPE=target): ${_tgt_cov}/${_tgt_total} ($(( _tgt_cov * 100 / _tgt_total ))%)"

      # Findings = entries cve-check marked exploitable, at or above SEVERITY,
      # minus anything the allowlist still covers.
      _sev_re=$(echo "$SEVERITY" | tr 'A-Z,' 'a-z|')
      SBOM_FINDINGS=0; SBOM_SUPPRESSED=0
      while IFS= read -r _id; do
        [[ -z "$_id" ]] && continue
        if is_allowed "$_id"; then SBOM_SUPPRESSED=$((SBOM_SUPPRESSED + 1))
        else SBOM_FINDINGS=$((SBOM_FINDINGS + 1)); echo "    ${_id}"; fi
      done < <(jq -r --arg sev "$_sev_re" '
                 [.vulnerabilities // [] | .[]
                  | select(.analysis.state == "exploitable")
                  | select([.ratings // [] | .[] | .severity // ""] | any(test($sev)))
                  | .id] | unique | .[]' "$GA_SBOM" 2>/dev/null || true)

      if [[ "$SBOM_COVERAGE" -lt "$COVERAGE_MIN_PCT" ]]; then
        echo "  ERROR: only ${SBOM_COVERAGE}% of SBOM components carry a matchable CPE (minimum ${COVERAGE_MIN_PCT}%)"
        SBOM_STATUS="no-coverage"
        SCAN_BROKEN=true
      elif [[ "$SBOM_FINDINGS" -gt 0 ]]; then
        echo "  FOUND: ${SBOM_FINDINGS} exploitable ${SEVERITY} vulnerabilities$([[ "$SBOM_SUPPRESSED" -gt 0 ]] && echo ", ${SBOM_SUPPRESSED} allowlisted")"
        SBOM_STATUS="findings"
        EXIT_CODE=1
      else
        echo "  CLEAN: no unsuppressed exploitable ${SEVERITY} findings across ${SBOM_SCANNED} matched packages$([[ "$SBOM_SUPPRESSED" -gt 0 ]] && echo " (${SBOM_SUPPRESSED} allowlisted)")"
        SBOM_STATUS="clean"
      fi

    # -- Fallback: no enrichment marker -> try trivy, which will almost -------
    # certainly cover nothing on a Buildroot SBOM and therefore exit 2.
    elif [[ "$HAVE_TRIVY" == "false" ]]; then
      echo "  ERROR: SBOM is not enriched (no ga:cve-check marker) and trivy is absent"
      echo "         — there is no scanner at all, so there is no result to trust"
      SBOM_STATUS="no-coverage"
    elif trivy sbom --severity "$SEVERITY" --list-all-pkgs --format json \
         --output "$REPORT" "$GA_SBOM" >"$SCANLOG" 2>&1; then

      # How many packages did the scanner actually take into account?
      SBOM_SCANNED=$(jq '[.Results[]?.Packages // []] | flatten | length' "$REPORT" 2>/dev/null || echo 0)
      if [[ "$SBOM_COMPONENTS" -gt 0 ]]; then
        SBOM_COVERAGE=$(( SBOM_SCANNED * 100 / SBOM_COMPONENTS ))
      fi
      read -r SBOM_FINDINGS SBOM_SUPPRESSED < <(count_unsuppressed "$REPORT") || true

      echo "  Packages evaluated: ${SBOM_SCANNED}/${SBOM_COMPONENTS} (${SBOM_COVERAGE}%)"

      # Known no-op signatures — trivy says these out loud before returning success
      if grep -qE 'Unsupported os|No OS package is detected|Supported files for scanner\(s\) not found' "$SCANLOG" 2>/dev/null; then
        echo ""
        echo "  ERROR: the scanner reported it could not handle this SBOM:"
        grep -E 'Unsupported os|No OS package is detected|Supported files for scanner\(s\) not found' "$SCANLOG" | sed 's/^/    /'
        SBOM_STATUS="no-coverage"
      elif [[ "$SBOM_COVERAGE" -lt "$COVERAGE_MIN_PCT" ]]; then
        echo ""
        echo "  ERROR: only ${SBOM_COVERAGE}% of SBOM components were evaluated (minimum ${COVERAGE_MIN_PCT}%)"
        SBOM_STATUS="no-coverage"
      elif [[ "$SBOM_FINDINGS" -gt 0 ]]; then
        echo "  FOUND: ${SBOM_FINDINGS} vulnerabilities (${SEVERITY})$([[ "$SBOM_SUPPRESSED" -gt 0 ]] && echo ", ${SBOM_SUPPRESSED} allowlisted")"
        trivy sbom --severity "$SEVERITY" --format table "$GA_SBOM" 2>/dev/null || true
        SBOM_STATUS="findings"
        EXIT_CODE=1
      else
        echo "  CLEAN: no unsuppressed ${SEVERITY} vulnerabilities in ${SBOM_SCANNED} OS packages"
        SBOM_STATUS="clean"
      fi
    else
      echo "  ERROR: SBOM scan failed (see ${SCANLOG})"
      tail -5 "$SCANLOG" 2>/dev/null | sed 's/^/    /'
      SBOM_STATUS="error"
    fi

    if [[ "$SBOM_STATUS" == "no-coverage" || "$SBOM_STATUS" == "error" ]]; then
      cat <<'EOF'

  ------------------------------------------------------------------------
  The OS package scan produced NO usable coverage. This is a BROKEN SCAN,
  not a clean result — do not read the empty report as "no vulnerabilities".

  Known cause: trivy cannot match Buildroot packages. It detects
  `family="buildroot"`, declares it unsupported, and returns success having
  evaluated nothing. Our CycloneDX components carry no `purl` (0/208), which
  is the identifier trivy's SBOM path keys on.

  Fix paths (see docs/CVE-HANDLING.md and KB #172):
    1. Buildroot's own `support/scripts/pkg-stats` — knows each package's
       CPE_ID, queries NVD itself, honours per-package _IGNORE_CVES.
    2. `grype` — matches on CPE, which our SBOM does carry (130/208).
    3. EMBA — binary-level analysis, independent of SBOM metadata.
  ------------------------------------------------------------------------
EOF
      SCAN_BROKEN=true
    fi
  else
    echo "  SKIP: no SBOM found at ${GA_SBOM}"
    echo "        (run a prod build first: ./scripts/ga_build.sh prod)"
    SBOM_STATUS="missing"
    # On a prod build a missing SBOM is a failure, not a skip.
    if [[ "${GA_ENV:-dev}" == "prod" ]]; then
      echo "  ERROR: GA_ENV=prod requires an SBOM — refusing to report success without one"
      SCAN_BROKEN=true
    fi
  fi
fi

# --- Machine-readable summary (consumed by CI and the build tests) ---
SUMMARY="${OUTPUT_DIR}/summary.json"
jq -n \
  --arg date "$(date -Iseconds)" \
  --arg severity "$SEVERITY" \
  --arg sbom_status "$SBOM_STATUS" \
  --argjson strict "$([[ "$STRICT" == "true" ]] && echo true || echo false)" \
  --argjson broken "$([[ "$SCAN_BROKEN" == "true" ]] && echo true || echo false)" \
  --argjson sbom_components "${SBOM_COMPONENTS:-0}" \
  --argjson sbom_scanned "${SBOM_SCANNED:-0}" \
  --argjson sbom_coverage "${SBOM_COVERAGE:-0}" \
  --argjson sbom_findings "${SBOM_FINDINGS:-0}" \
  --argjson sbom_suppressed "${SBOM_SUPPRESSED:-0}" \
  --argjson img_total "${IMG_TOTAL:-0}" \
  --argjson img_findings "${IMG_FINDINGS:-0}" \
  --argjson img_suppressed "${IMG_SUPPRESSED:-0}" \
  --argjson allow_expired "${allow_expired:-0}" \
  '{date:$date, severity:$severity, strict:$strict, scan_broken:$broken,
    allowlist_expired:$allow_expired,
    os:{status:$sbom_status, components:$sbom_components, scanned:$sbom_scanned,
        coverage_pct:$sbom_coverage, findings:$sbom_findings, suppressed:$sbom_suppressed},
    images:{total:$img_total, findings:$img_findings, suppressed:$img_suppressed}}' \
  > "$SUMMARY" 2>/dev/null || echo "WARN: could not write ${SUMMARY}"

echo ""
echo "=== Scan Complete ==="
echo "  Results saved to: ${OUTPUT_DIR}/"
echo "  Summary:          ${SUMMARY}"

# A broken scan is always fatal — it is the one result we must never wave through.
if [[ "$SCAN_BROKEN" == "true" ]]; then
  echo "  Result: BROKEN SCAN (exit 2)"
  exit 2
fi

if [[ "$EXIT_CODE" -ne 0 ]]; then
  if [[ "$STRICT" == "true" ]]; then
    echo "  Result: findings above budget, strict mode (exit 1)"
    exit 1
  fi
  echo "  Result: findings above budget — reporting only (strict=false), exit 0"
  echo "          Triage them into ${ALLOW_FILE} or fix them, then enable --strict."
  exit 0
fi

echo "  Result: OK (exit 0)"
exit 0
