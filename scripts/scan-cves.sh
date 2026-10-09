#!/usr/bin/env bash
# scan-cves.sh — Scan GA OS components for known vulnerabilities
#
# Usage:
#   ./scripts/scan-cves.sh                    # scan all
#   ./scripts/scan-cves.sh --images           # container images only
#   ./scripts/scan-cves.sh --sbom             # SBOM only (after a build)
#   ./scripts/scan-cves.sh --severity HIGH    # filter by min severity
#   ./scripts/scan-cves.sh --strict           # OS (SBOM) findings over budget are fatal too
#   ./scripts/scan-cves.sh --image-tars DIR   # scan saved image tarballs (the bake)
#   ./scripts/scan-cves.sh --images --channel stable   # images of another channel
#   ./scripts/scan-cves.sh --rootfs DIR       # Go binaries of a built root filesystem
#   ./scripts/scan-cves.sh --sbom --strict --package-coverage   # + per-package coverage
#
# Exit codes (distinct on purpose — see COVERAGE below):
#   0  clean, or findings within the policy
#   1  OS SBOM: the D1 policy blocks (fatal only with --strict)
#      images / rootfs: the D1 policy blocks (see POLICY below)
#   2  the scan itself is broken          (ALWAYS fatal, never suppressed)
#
# POLICY for the OS SBOM (D1, applied to the OS 2026-10-09):
#   Only GATE-class findings (shipped userland, see docs/CVE-SCANNING-POSTURE.md)
#   can block. Of those, a CRITICAL with a fixed upstream version blocks; HIGH,
#   and CRITICAL without a fix, are reported. The fix comes from the finding's
#   `ga:fixed-in` property (scripts/sbom-cve-annotate.py, read from NVD); a
#   CRITICAL WITHOUT that property is treated as fixable — fail closed.
#
# ROOTFS (--rootfs DIR, 2026-10-09): the Go binaries Buildroot installs into the
#   root filesystem (netbird, telegraf, os-agent, runc, docker, containerd …)
#   carry no CPE, so the SBOM scan above cannot see them. They are scanned here
#   by their Go build info (trivy rootfs; syft inventory; grype second opinion
#   for a binary trivy skipped), under the same D1 policy and allowlist. A scan
#   that evaluated no Go binary, or misses one of the expected binaries
#   (ROOTFS_GO_EXPECTED, or --expect-go a,b,c), is BROKEN (exit 2).
#
# PACKAGE COVERAGE (--package-coverage, 2026-10-09): every package the GA
#   defconfig adds on top of the upstream one must be classified in
#   scripts/cve-package-coverage.conf, and a package classified `nvd` must have
#   matched at least one NVD entry (`ga:nvd-matches`). A CPE that matches
#   nothing looks exactly like a package without vulnerabilities, so an
#   unmatched or unclassified package is a BROKEN scan (exit 2), not a clean one.
#
# POLICY (container images; decided 2026-09-29, "D1"):
#   A CRITICAL finding that has a fix available BLOCKS (exit 1).
#   HIGH findings, and CRITICAL ones without a fix, are reported, never blocking.
#   The only exception is an allowlist entry with a reason and an expiry at most
#   30 days out. `--policy report` turns the image half into report-only for
#   ad-hoc runs; the default is the decided policy.
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
# GO BINARY COVERAGE (container images, 2026-09-30):
#   Counting packages per image is not enough: trivy can evaluate most Go
#   binaries of an image and silently skip others — no result, no warning, so a
#   skipped binary reads as a clean one. Every image is therefore also
#   catalogued with syft, and every executable carrying Go build info must
#   appear as a trivy `gobinary` target. A binary trivy did not evaluate gets a
#   second opinion from grype (same D1 policy, same allowlist). A binary that
#   neither scanner evaluated makes the image BLIND (exit 2), never clean.
#   The inventory is the union of syft's list and trivy's gobinary results;
#   a binary only trivy saw is covered but reported (INVENTORY GAP).
#
# Requires: trivy (https://aquasecurity.github.io/trivy/)
#   Images also require syft (the Go binary inventory) and, when trivy missed a
#   Go binary, grype (the second opinion). Versions: pinned in the Dockerfile.
#   Install: the versions pinned in the Dockerfile (trivy, syft, grype).
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
# Report-only by default for ad-hoc runs. The build arms the gate with an
# explicit --strict at its call site (ga_build.sh, CVE-SCAN-06) — not through an
# ambient variable, which is how a build-mode switch could silently disarm it.
STRICT=false
# Image policy — see POLICY in the header. Deliberately NOT read from the
# environment: an ambient variable is how a gate gets disarmed without a diff.
POLICY="d1"
# An allowlist entry may suppress a finding for at most this many days (D1).
# A constant, not a knob, for the same reason.
readonly ALLOW_MAX_DAYS=30
# Saved image tarballs to scan instead of pulling from a registry (the bake).
IMAGE_TARS=""
# Root filesystem to scan for Go binaries (--rootfs), and the binaries that
# MUST be among the evaluated ones. A constant, not derived from the tree that
# is being scanned: an expectation read from the artefact goes green with it.
ROOTFS=""
ROOTFS_GO_EXPECTED="netbird telegraf os-agent runc dockerd containerd"
# Per-package coverage of the GA defconfig delta (--package-coverage).
PACKAGE_COVERAGE=false
COVERAGE_CONF="${COVERAGE_CONF:-${SCRIPT_DIR}/cve-package-coverage.conf}"
GA_DEFCONFIG="${GA_DEFCONFIG:-${REPO_ROOT}/buildroot-ihost/configs/ga_ihost_full_defconfig}"
BASE_DEFCONFIG="${BASE_DEFCONFIG:-${REPO_ROOT}/buildroot-ihost/configs/ihost_full_defconfig}"
# Symbols the delta parser MUST find — if it stops seeing these, it has lost
# its subject, and an empty delta would otherwise pass as "nothing to cover".
readonly COVERAGE_MUST_SEE="FLUENT_BIT OPENSSH NFTABLES NETBIRD TELEGRAF"
# Which haos-version channel the pulled system images come from. Empty = the
# channel the bake uses (read from the defconfig below), so the scheduled scan
# looks at what the next image ships, not at a hard-coded channel.
CHANNEL=""

EXIT_CODE=0
SCAN_BROKEN=false

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --images)   SCAN_SBOM=false;  shift ;;
    --image-tars) SCAN_SBOM=false; IMAGE_TARS="$2"; shift 2 ;;
    --sbom)     SCAN_IMAGES=false; shift ;;
    --rootfs)   SCAN_SBOM=false; SCAN_IMAGES=false; ROOTFS="${2:-}"; shift 2 ;;
    --expect-go) ROOTFS_GO_EXPECTED="${2//,/ }"; shift 2 ;;
    --package-coverage) PACKAGE_COVERAGE=true; shift ;;
    --severity) SEVERITY="$2";    shift 2 ;;
    --strict)   STRICT=true;      shift ;;
    --no-strict) STRICT=false;    shift ;;
    --policy)
      case "$2" in d1|report) POLICY="$2" ;; *) echo "Unknown policy: $2 (d1|report)"; exit 2 ;; esac
      shift 2 ;;
    --channel)
      case "$2" in stable|beta|dev) CHANNEL="$2" ;; *) echo "Unknown channel: $2 (stable|beta|dev)"; exit 2 ;; esac
      shift 2 ;;
    --help|-h)
      sed -n '2,76p' "$0"
      exit 0
      ;;
    # A usage error exits 2 ("the scan did not run"), never 1: callers read 1
    # as "the policy blocks", and a typo must not be reported as a finding.
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

# #8 of the 2026-09-29 review: under the decided policy CRITICAL must be in the
# severity set, or the policy would silently see nothing to block.
if [[ "$POLICY" == "d1" && ( "$SCAN_IMAGES" == "true" || -n "$ROOTFS" ) && ",${SEVERITY}," != *",CRITICAL,"* ]]; then
  echo "ERROR: --severity '${SEVERITY}' leaves out CRITICAL — the image policy could not see what it has to block"
  exit 2
fi

# trivy is required for the container images and for the OS fallback path, but
# NOT for an SBOM already enriched by cve-check — that path reads CycloneDX
# directly. Check where it is actually needed rather than up front.
HAVE_TRIVY=true
command -v trivy &>/dev/null || HAVE_TRIVY=false
if [[ "$HAVE_TRIVY" == "false" && "$SCAN_IMAGES" == "true" ]]; then
  echo "ERROR: trivy not found — the container image scan cannot run. Install the"
  echo "       version pinned in the Dockerfile."
  exit 2
fi
# syft is what makes the image verdict checkable per Go binary (see GO BINARY
# COVERAGE). Without it the coverage assertion cannot run — broken, not skipped.
if [[ -n "$ROOTFS" ]]; then
  if [[ ! -d "$ROOTFS" ]]; then
    echo "ERROR: --rootfs '${ROOTFS}' is not a directory — nothing to scan is not clean"
    exit 2
  fi
  for _t in trivy syft; do
    command -v "$_t" &>/dev/null || { echo "ERROR: ${_t} not found — the rootfs Go binary scan cannot run (versions: Dockerfile)"; exit 2; }
  done
fi
if [[ "$SCAN_IMAGES" == "true" ]] && ! command -v syft &>/dev/null; then
  echo "ERROR: syft not found — cannot inventory the Go binaries in the images, so"
  echo "       trivy's coverage of them cannot be asserted. Install the version pinned"
  echo "       in the Dockerfile (anchore/syft)."
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
echo "=== GA OS CVE Scan ==="
echo "  Date:     $(date -Iseconds)"
echo "  Severity: ${SEVERITY}"
echo "  Strict:   ${STRICT}"
echo "  Policy:   ${POLICY} (images, rootfs; OS SBOM with --strict)"
echo ""

# -----------------------------------------------------------------------------
# Allowlist — accepted findings, each with an owner, an expiry date and a reason.
#
# Format (one per line, '#' comments and blank lines ignored):
#   CVE-2025-1234  owner-handle  2026-12-31  reason text
#
# An entry stops suppressing on its expiry date. That is deliberate: a gate
# without an allowlist gets switched off within two weeks, and an allowlist
# without expiry dates becomes permanent amnesia.
#
# D1 (2026-09-29): the reason is mandatory and the expiry may be at most
# ALLOW_MAX_DAYS out. An entry breaking either rule suppresses NOTHING and is
# reported loudly — a silently honoured long-lived exception is exactly the
# amnesia the expiry exists to prevent.
# -----------------------------------------------------------------------------
ALLOWED_CVES=()
allow_expired=0
allow_invalid=0
load_allowlist() {
  [[ -f "$ALLOW_FILE" ]] || return 0
  local today; today="$(date +%Y-%m-%d)"
  local latest; latest="$(date -d "+${ALLOW_MAX_DAYS} days" +%Y-%m-%d)"
  local cve owner expiry reason
  # `|| [[ -n ... ]]`: a last line without a trailing newline is still an entry.
  while read -r cve owner expiry reason || [[ -n "${cve:-}" ]]; do
    [[ -z "${cve:-}" || "${cve:0:1}" == "#" ]] && continue
    if [[ ! "${expiry:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      echo "  WARN: allowlist entry '${cve}' has no valid expiry date — ignoring it"
      allow_invalid=$((allow_invalid + 1))
      continue
    fi
    if [[ -z "${reason// /}" ]]; then
      echo "  WARN: allowlist entry ${cve} has NO REASON — an exception needs one; ignoring it"
      allow_invalid=$((allow_invalid + 1))
      continue
    fi
    if [[ "$expiry" > "$latest" ]]; then
      echo "  WARN: allowlist entry ${cve} expires ${expiry}, more than ${ALLOW_MAX_DAYS} days out (latest allowed ${latest}) — ignoring it"
      allow_invalid=$((allow_invalid + 1))
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
#
# Coverage: a verdict about an image is only believed if trivy demonstrably
# evaluated packages in it. OS packages AND language packages count — a
# distroless image (one Go binary, no package DB) is fully covered by its
# gobinary result, and calling it "blind" was a false alarm that kept the
# scheduled scan red on an image the bake scanned fine.
#
# Unscannable is not skippable: an image that cannot be pulled or read was NOT
# scanned, so any such image makes the whole result BROKEN (exit 2). Reporting
# "7 scanned, 7 skipped" as a pass is how a scan stays red for weeks while
# everyone reads the colour as noise.
IMG_TOTAL=0; IMG_PASS=0; IMG_FAIL=0; IMG_FINDINGS=0; IMG_SUPPRESSED=0; IMG_BLIND=0
IMG_BLOCKING=0; IMG_BLOCKED=0; img_unscannable=0
# Go binary coverage (see GO BINARY COVERAGE in the header): inventoried by
# syft, evaluated by trivy, evaluated by grype as the second opinion, by neither.
GO_BINARIES=0; GO_BY_TRIVY=0; GO_BY_GRYPE=0; GO_BLIND=0; GO_INVENTORY_GAP=0
IMG_SOURCE="none"
IMG_LIST_FILE=/dev/null   # set to a real file only when images are scanned
UNSCANNABLE_NAMES=()
BLIND_BINARY_NAMES=()
SYFT_PLATFORM=""          # registry mode asks for linux/arm/v7, like trivy

# go_binary_inventory <syft-json>: every executable syft found Go build info
# in, spelled like trivy's Target (no leading slash), one per line. It reads
# the image's files; nothing in the image is executed.
go_binary_inventory() {
  jq -r '[.artifacts[]? | select(.foundBy == "go-module-binary-cataloger")
          | .locations[]?.path // empty | ltrimstr("/")] | unique | .[]' "$1"
}

# trivy_go_targets <trivy-json>: the Go binaries trivy actually evaluated.
trivy_go_targets() {
  jq -r '[.Results[]? | select(.Type == "gobinary") | .Target | ltrimstr("/")] | unique | .[]' "$1"
}

# second_opinion <syft-json> <grype-json> <path>...: grype over exactly the Go
# modules of the named binaries (a filtered syft inventory; nothing extracted,
# nothing run). Succeeds only if every named binary contributed packages AND
# grype produced a report — anything less is not an evaluation.
second_opinion() {
  local inv="$1" out="$2"; shift 2
  local sub="${out%.json}.sbom.json" want have x
  if ! command -v grype &>/dev/null; then
    echo "  ERROR: grype not found — no second opinion for the Go binaries trivy did not evaluate"
    return 1
  fi
  want=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
  jq --argjson want "$want" '
      .artifacts |= map(select(.foundBy == "go-module-binary-cataloger")
        | select([.locations[]?.path // empty | ltrimstr("/")] as $l
                 | [$want[] as $w | $l[] | select(. == $w)] | length > 0))
      | .artifactRelationships = []' "$inv" > "$sub" 2>/dev/null || { echo "  ERROR: could not cut the inventory down to the missed binaries"; return 1; }
  have=$(jq -r '[.artifacts[]?.locations[]?.path // empty | ltrimstr("/")] | unique | .[]' "$sub" 2>/dev/null || true)
  for x in "$@"; do
    grep -qxF -- "$x" <<<"$have" || { echo "  ERROR: no Go modules of ${x} in the inventory — grype would evaluate nothing for it"; return 1; }
  done
  if ! grype "sbom:${sub}" -o json --file "$out" -q 2>"${out%.json}.err"; then
    echo "  ERROR: grype failed: $(tail -n1 "${out%.json}.err" 2>/dev/null | cut -c1-240)"
    return 1
  fi
  jq -e 'has("matches")' "$out" >/dev/null 2>&1 || { echo "  ERROR: grype produced no parseable report"; return 1; }
}

# grype_policy <grype-json>: prints "<findings> <suppressed> <blocking>" — the
# same rules as for trivy: only severities in SEVERITY; an allowlist entry
# matches the finding's id (GHSA/GO/CVE) or one of its related CVE ids;
# blocking = distinct CRITICAL ids with a fix available, not allowlisted (D1).
grype_policy() {
  local report="$1" n=0 s=0 sev fix id rel allowed r
  local -A blk=()
  while IFS=$'\t' read -r sev fix id rel; do
    [[ -z "${id:-}" ]] && continue
    [[ ",${SEVERITY}," == *",${sev},"* ]] || continue
    # `if`, not `&&`: a false `&&` as a loop's last command is a non-zero
    # status, which under `set -e` ends this (process-substituted) function early.
    allowed=false
    if is_allowed "$id"; then allowed=true; fi
    for r in ${rel//,/ }; do if is_allowed "$r"; then allowed=true; fi; done
    if [[ "$allowed" == "true" ]]; then s=$((s + 1)); continue; fi
    n=$((n + 1))
    if [[ "$sev" == "CRITICAL" && "$fix" == "fixed" ]]; then blk["$id"]=1; fi
  done < <(jq -r '[.matches[]? | [(.vulnerability.severity // "" | ascii_upcase),
                   (.vulnerability.fix.state // ""), .vulnerability.id,
                   ([.relatedVulnerabilities[]?.id] | join(",")),
                   .artifact.name, (.artifact.locations[0].path // "")]]
                 | unique | .[] | @tsv' "$report" 2>/dev/null | cut -f1-4 || true)
  printf '%s %s %s\n' "$n" "$s" "${#blk[@]}"
}

# scan_one_image <label> <syft-source> <trivy target args...>
scan_one_image() {
  local label="$1" syft_src="$2"; shift 2
  local report pkgs n s b state base
  base="${OUTPUT_DIR}/image-$(printf '%s' "$label" | tr '/:@' '___')"
  report="${base}.json"
  echo ""
  echo "--- Scanning: ${label} ---"
  # --list-all-pkgs is what turns "no findings" into a CHECKABLE claim: trivy
  # reports every package it CONSIDERED, so a verdict of "clean" can be held
  # against the number of packages it actually looked at.
  if ! trivy image --severity "$SEVERITY" --list-all-pkgs --format json --output "$report" "$@" 2>"${report%.json}.err"; then
    echo "  ERROR: could not scan ${label} (not pullable / not readable) — NOT scanned, not clean"
    echo "         cause: $(grep -E 'FATAL|ERROR|error' "${report%.json}.err" 2>/dev/null | tail -n1 | cut -c1-240)"
    img_unscannable=$((img_unscannable + 1)); UNSCANNABLE_NAMES+=("$label")
    jq -cn --arg i "$label" '{image:$i, state:"unscannable"}' >> "$IMG_LIST_FILE"
    return 0
  fi
  pkgs=$(jq '[.Results[]? | select(.Class == "os-pkgs" or .Class == "lang-pkgs") | .Packages // []] | flatten | length' "$report" 2>/dev/null || echo 0)
  # Language packages cover a distroless image, but they must not paper over an
  # OS layer trivy detected and then evaluated nothing in: if an OS family was
  # detected, OS packages have to be there too.
  local os_family os_pkgs
  os_family=$(jq -r '.Metadata.OS.Family // empty' "$report" 2>/dev/null || true)
  os_pkgs=$(jq '[.Results[]? | select(.Class == "os-pkgs") | .Packages // []] | flatten | length' "$report" 2>/dev/null || echo 0)
  if [[ -n "$os_family" && "${os_pkgs:-0}" -eq 0 ]]; then
    echo "  ERROR: BLIND SCAN — OS '${os_family}' detected but ZERO OS packages evaluated in this image."
    echo "         Its language packages do not make up for an unscanned OS layer."
    IMG_BLIND=$((IMG_BLIND + 1))
    jq -cn --arg i "$label" --arg f "$os_family" '{image:$i, state:"blind", os_family:$f, packages:0}' >> "$IMG_LIST_FILE"
    return 0
  fi
  if [[ "${pkgs:-0}" -eq 0 ]]; then
    # NOT a clean image. Trivy returns success having evaluated nothing when
    # it has no matcher for the image's package family — the empty report is
    # indistinguishable from a clean one unless you count.
    echo "  ERROR: BLIND SCAN — trivy evaluated ZERO packages (OS or language) in this image."
    echo "         An empty report is not a clean report. Not counted as clean."
    IMG_BLIND=$((IMG_BLIND + 1))
    jq -cn --arg i "$label" '{image:$i, state:"blind", packages:0}' >> "$IMG_LIST_FILE"
    return 0
  fi

  # --- Go binary coverage: every Go binary in the image must have been
  # evaluated. trivy can skip a Go binary without a word (no result at all), so
  # its package count proves nothing about the binaries it never looked at.
  local inv="${base}.syft.json" x
  local syft_args=(scan "$syft_src" -o "syft-json=${inv}" -q)
  if [[ -n "$SYFT_PLATFORM" ]]; then syft_args+=(--platform "$SYFT_PLATFORM"); fi
  if ! syft "${syft_args[@]}" 2>"${base}.syft.err" || ! jq -e 'has("artifacts")' "$inv" >/dev/null 2>&1; then
    echo "  ERROR: could not inventory the Go binaries of ${label} (syft) — trivy's coverage of"
    echo "         them cannot be asserted, so the image is NOT scanned, not clean"
    echo "         cause: $(tail -n1 "${base}.syft.err" 2>/dev/null | cut -c1-240)"
    img_unscannable=$((img_unscannable + 1)); UNSCANNABLE_NAMES+=("$label (no Go binary inventory)")
    jq -cn --arg i "$label" '{image:$i, state:"unscannable", reason:"go-binary-inventory"}' >> "$IMG_LIST_FILE"
    return 0
  fi
  local go_all=() go_trivy missed=() blind=() gap=()
  mapfile -t go_all < <(go_binary_inventory "$inv")
  go_trivy=$(trivy_go_targets "$report")
  for x in ${go_all[@]+"${go_all[@]}"}; do
    grep -qxF -- "$x" <<<"$go_trivy" || missed+=("$x")
  done
  # Neither tool's list is complete on its own: measured 2026-09-30, trivy
  # skipped Go binaries syft listed, and syft skipped one trivy evaluated. The
  # inventory is therefore the UNION. A binary only trivy saw is covered (trivy
  # evaluated it) but is reported loudly and counted — it is evidence the syft
  # half of the inventory is short, and a binary BOTH tools miss is invisible
  # to this check (stated, not hidden: see docs/CVE-HANDLING.md).
  while IFS= read -r x; do
    [[ -z "$x" ]] && continue
    printf '%s\n' ${go_all[@]+"${go_all[@]}"} | grep -qxF -- "$x" || gap+=("$x")
  done <<<"$go_trivy"
  if [[ ${#gap[@]} -gt 0 ]]; then
    echo "  WARN: INVENTORY GAP — trivy evaluated Go binar(ies) syft did not list: ${gap[*]}"
    echo "        Covered by trivy; counted in the summary (go_binaries.inventory_gap)."
    GO_INVENTORY_GAP=$((GO_INVENTORY_GAP + ${#gap[@]}))
  fi
  GO_BINARIES=$((GO_BINARIES + ${#go_all[@]} + ${#gap[@]}))
  GO_BY_TRIVY=$((GO_BY_TRIVY + ${#go_all[@]} - ${#missed[@]} + ${#gap[@]}))

  local g_n=0 g_s=0 g_b=0 second="none"
  if [[ ${#missed[@]} -gt 0 ]]; then
    echo "  WARN: trivy did NOT evaluate ${#missed[@]} of ${#go_all[@]} Go binar(ies) in this image: ${missed[*]}"
    echo "        Second opinion (grype) for exactly those; the same policy applies."
    if second_opinion "$inv" "${base}.grype.json" "${missed[@]}"; then
      second="grype"; GO_BY_GRYPE=$((GO_BY_GRYPE + ${#missed[@]}))
      read -r g_n g_s g_b < <(grype_policy "${base}.grype.json") || true
      echo "  grype: ${g_n} ${SEVERITY} finding(s)$([[ "$g_s" -gt 0 ]] && echo ", ${g_s} allowlisted"); fixable CRITICAL not allowlisted: ${g_b}"
      jq -r --arg sev ",${SEVERITY}," '[.matches[]?
              | select($sev | contains("," + (.vulnerability.severity // "" | ascii_upcase) + ","))
              | [(.vulnerability.severity | ascii_upcase), .vulnerability.id, .artifact.name,
                 (.artifact.version // "?"),
                 (if (.vulnerability.fix.state // "") == "fixed" then (.vulnerability.fix.versions | join(",")) else "no fixed version" end),
                 (.artifact.locations[0].path // "?")] | @tsv]
             | unique | .[]' "${base}.grype.json" 2>/dev/null \
        | awk -F'\t' '{printf "    %-8s %-20s %s %s -> %s  (grype: %s)\n", $1, $2, $3, $4, $5, $6}' || true
    else
      blind+=("${missed[@]}")
    fi
  fi

  read -r n s < <(count_unsuppressed "$report") || true
  # D1: CRITICAL with a fix available, and not covered by a valid allowlist entry.
  b=0
  local id
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    is_allowed "$id" || { b=$((b + 1)); }
  done < <(jq -r '[.Results[]?.Vulnerabilities // []] | flatten | .[]
                  | select(.Severity == "CRITICAL")
                  | select(((.FixedVersion // "") != "") or (.Status == "fixed"))
                  | .VulnerabilityID' "$report" 2>/dev/null | sort -u || true)
  n=$((n + g_n)); s=$((s + g_s)); b=$((b + g_b))
  IMG_FINDINGS=$((IMG_FINDINGS + n)); IMG_SUPPRESSED=$((IMG_SUPPRESSED + s))
  if [[ ${#blind[@]} -gt 0 ]]; then
    # Not clean and not "with findings": part of this image was never evaluated.
    state="blind"; IMG_BLIND=$((IMG_BLIND + 1)); GO_BLIND=$((GO_BLIND + ${#blind[@]}))
    echo "  ERROR: BLIND SCAN — ${#blind[@]} Go binar(ies) in this image were evaluated by NO scanner:"
    for x in "${blind[@]}"; do echo "           ${x}"; BLIND_BINARY_NAMES+=("${label}: ${x}"); done
  elif [[ "$n" -gt 0 ]]; then
    state="findings"; IMG_FAIL=$((IMG_FAIL + 1))
    echo "  FOUND: ${n} ${SEVERITY} finding(s) across ${pkgs} evaluated package(s)$([[ "$s" -gt 0 ]] && echo ", ${s} allowlisted"); fixable CRITICAL not allowlisted: ${b}"
  else
    state="clean"; IMG_PASS=$((IMG_PASS + 1))
    echo "  CLEAN: no unsuppressed ${SEVERITY} findings across ${pkgs} evaluated package(s) and ${#go_all[@]} Go binar(ies)$([[ "$s" -gt 0 ]] && echo " (${s} allowlisted)")"
  fi
  if [[ "$n" -gt 0 ]]; then
    # One line per finding from the report already in hand — no second scan.
    jq -r '[.Results[]? | .Target as $t | (.Vulnerabilities // [])[]
            | [.Severity, .VulnerabilityID, .PkgName, (.InstalledVersion // "?"),
               (if ((.FixedVersion // "") != "") then .FixedVersion else "none published" end)] | @tsv]
           | unique | .[]' "$report" 2>/dev/null \
      | awk -F'\t' '{printf "    %-8s %-20s %s %s -> %s\n", $1, $2, $3, $4, $5}' || true
  fi
  if [[ "$b" -gt 0 ]]; then
    IMG_BLOCKING=$((IMG_BLOCKING + b)); IMG_BLOCKED=$((IMG_BLOCKED + 1))
  fi
  jq -cn --arg i "$label" --arg st "$state" --argjson p "$pkgs" --argjson n "$n" --argjson s "$s" --argjson b "$b" \
     --argjson go "$(( ${#go_all[@]} + ${#gap[@]} ))" --arg second "$second" \
     --argjson gap "$(printf '%s\n' ${gap[@]+"${gap[@]}"} | jq -R 'select(length > 0)' | jq -sc .)" \
     --argjson missed "$(printf '%s\n' ${missed[@]+"${missed[@]}"} | jq -R 'select(length > 0)' | jq -sc .)" \
     --argjson blindb "$(printf '%s\n' ${blind[@]+"${blind[@]}"} | jq -R 'select(length > 0)' | jq -sc .)" \
     '{image:$i, state:$st, packages:$p, findings:$n, suppressed:$s, blocking:$b,
       go_binaries:$go, trivy_missed:$missed, inventory_gap:$gap, second_opinion:$second, blind_binaries:$blindb}' >> "$IMG_LIST_FILE"
  return 0
}

# Channel the bake uses, from the defconfig — so the scheduled scan follows it.
build_channel() {
  local dc="${REPO_ROOT}/buildroot-ihost/configs/ga_ihost_full_defconfig" c
  c=$(sed -n 's/^BR2_PACKAGE_HASSIO_CHANNEL_\(STABLE\|BETA\|DEV\)=y$/\1/p' "$dc" 2>/dev/null | head -n1)
  [[ -n "$c" ]] && echo "${c,,}"
}

if [[ "$SCAN_IMAGES" == "true" ]]; then
  IMG_LIST_FILE="${OUTPUT_DIR}/images.jsonl"
  : > "$IMG_LIST_FILE"
  if [[ -n "$IMAGE_TARS" ]]; then
    echo "=== Scanning Container Image Tarballs: ${IMAGE_TARS} ==="
    IMG_SOURCE="tarballs"
    _tars=()
    for _t in "$IMAGE_TARS"/*.tar; do [[ -f "$_t" ]] && _tars+=("$_t"); done
    IMG_TOTAL=${#_tars[@]}
    if [[ "$IMG_TOTAL" -eq 0 ]]; then
      echo "  ERROR: no *.tar in ${IMAGE_TARS} — nothing was scanned, which is not clean"
      SCAN_BROKEN=true
    fi
    for _t in ${_tars[@]+"${_tars[@]}"}; do
      scan_one_image "$(basename "$_t" .tar)" "docker-archive:${_t}" --input "$_t"
    done
  else
    echo "=== Scanning Container Images ==="
    ADDON_JSON="${REPO_ROOT}/buildroot-external/package/hassio/addon-images.json"
    ARCH="armv7"
    MACHINE="tinker"
    [[ -n "$CHANNEL" ]] || CHANNEL="$(build_channel)"
    if [[ -z "$CHANNEL" ]]; then
      echo "  ERROR: no channel given and none found in the defconfig — cannot tell which images ship"
      SCAN_BROKEN=true
      CHANNEL="unknown"
    fi
    IMG_SOURCE="channel:${CHANNEL}"
    # Default = the branch the BUILD reads (hassio.mk), not a hardcoded main/:
    # during an rc dress rehearsal the image bakes from a candidate branch.
    _mk_url="$(sed -nE 's/^HASSIO_VERSION_URL[[:space:]]*\??=[[:space:]]*"([^"]+)"[[:space:]]*$/\1/p' \
      "${REPO_ROOT}/buildroot-external/package/hassio/hassio.mk" 2>/dev/null | head -1 || true)"
    if [[ -z "${HASSIO_VERSION_URL:-}" && -z "$_mk_url" ]]; then
      echo "  ERROR: no HASSIO_VERSION_URL in hassio.mk and none given — cannot tell which images ship"
      SCAN_BROKEN=true
    fi
    VERSION_URL="${HASSIO_VERSION_URL:-${_mk_url}}${CHANNEL}.json"
    echo "  Channel:  ${CHANNEL} (${VERSION_URL})"
    STABLE=""
    [[ "$CHANNEL" != "unknown" ]] && STABLE=$(curl -sf "$VERSION_URL" 2>/dev/null || true)

    IMAGES=()
    if [[ -n "$STABLE" ]]; then
      # Core: the template may use {machine} or {arch}
      CORE_TMPL=$(echo "$STABLE" | jq -r '.images.core // empty')
      CORE_VER=$(echo "$STABLE" | jq -r ".homeassistant.${MACHINE} // .homeassistant.default // empty")
      CORE_IMG="${CORE_TMPL//\{machine\}/$MACHINE}"; CORE_IMG="${CORE_IMG//\{arch\}/$ARCH}"
      [[ -n "$CORE_IMG" && -n "$CORE_VER" ]] && IMAGES+=("${CORE_IMG}:${CORE_VER}")

      SUP_TMPL=$(echo "$STABLE" | jq -r '.images.supervisor // empty')
      SUP_VER=$(echo "$STABLE" | jq -r '.supervisor // empty')
      SUP_IMG="${SUP_TMPL//\{arch\}/$ARCH}"
      [[ -n "$SUP_IMG" && -n "$SUP_VER" ]] && IMAGES+=("${SUP_IMG}:${SUP_VER}")

      for comp in cli dns audio observer multicast; do
        IMG_TMPL=$(echo "$STABLE" | jq -r ".images.${comp} // empty")
        COMP_VER=$(echo "$STABLE" | jq -r ".${comp} // empty")
        IMG="${IMG_TMPL//\{arch\}/$ARCH}"
        [[ -n "$IMG" && -n "$COMP_VER" ]] && IMAGES+=("${IMG}:${COMP_VER}")
      done
    else
      # Not a warning any more: the system images (Core, Supervisor, plugins)
      # are the bulk of what ships. Without the channel file they were silently
      # left out and the rest was reported as if it were the whole picture.
      echo "  ERROR: could not fetch ${VERSION_URL} — the system images cannot be scanned"
      SCAN_BROKEN=true
    fi

    if [[ -f "$ADDON_JSON" ]]; then
      while IFS= read -r img; do
        IMAGES+=("${img//\{arch\}/$ARCH}")
      done < <(jq -r '.addons | to_entries[] | "\(.value.image):\(.value.version)"' "$ADDON_JSON" 2>/dev/null || true)
    fi

    IMG_TOTAL=${#IMAGES[@]}
    # The images are armv7-only indexes (plus attestation entries). Without an
    # explicit platform trivy looks for the runner's own (linux/amd64), finds
    # none and fails — that alone made every armv7-only index "unscannable"
    # while single-manifest images of the same arch scanned fine.
    PLATFORM="linux/arm/v7"
    SYFT_PLATFORM="$PLATFORM"
    for img in ${IMAGES[@]+"${IMAGES[@]}"}; do
      scan_one_image "$img" "registry:${img}" --platform "$PLATFORM" "$img"
    done
  fi

  echo ""
  echo "=== Image Scan Summary: ${IMG_PASS} clean, ${IMG_FAIL} with findings, ${IMG_BLIND} blind, ${img_unscannable} unscannable (${IMG_TOTAL} total) ==="
  echo "    Policy ${POLICY}: ${IMG_BLOCKING} fixable CRITICAL finding(s) not allowlisted, in ${IMG_BLOCKED} image(s)"
  echo "    Go binaries: ${GO_BINARIES} inventoried, ${GO_BY_TRIVY} evaluated by trivy, ${GO_BY_GRYPE} by grype (second opinion), ${GO_BLIND} by neither; ${GO_INVENTORY_GAP} seen by trivy only"

  if [[ "$img_unscannable" -gt 0 ]]; then
    echo "  ERROR: ${img_unscannable} of ${IMG_TOTAL} image(s) could not be scanned — the image scan is BROKEN, not clean:"
    printf '           %s\n' "${UNSCANNABLE_NAMES[@]}"
    echo "         For private registry images the scanning job needs read access to"
    echo "         those packages (package settings -> Manage Actions access)."
    SCAN_BROKEN=true
  fi

  # An image trivy could pull but not understand is the WORSE failure: it looks
  # like a successful scan. One is enough to make the summary a false claim, so
  # it is a broken scan (exit 2), never a finding (exit 1) — you cannot triage a
  # vulnerability list that was never produced.
  if [[ "$IMG_BLIND" -gt 0 ]]; then
    echo "  ERROR: ${IMG_BLIND} of ${IMG_TOTAL} image(s) were not evaluated in full — the image scan"
    echo "         is BROKEN for those, not clean. Either no package at all was evaluated"
    echo "         (most likely a base trivy has no package matcher for), or Go binaries"
    echo "         were evaluated by no scanner:"
    for _b in ${BLIND_BINARY_NAMES[@]+"${BLIND_BINARY_NAMES[@]}"}; do echo "           ${_b}"; done
    SCAN_BROKEN=true
  fi
fi

# -----------------------------------------------------------------------------
# Root filesystem: the Go binaries (--rootfs DIR)
#
# The SBOM scan matches packages by CPE. Buildroot's Go packages carry none
# (netbird, telegraf, os-agent) or one NVD rarely uses, so until 2026-10-09
# their Go modules — where almost all of their CVEs live — were scanned by
# nothing, and a finding in them could not fail any gate. This half reads the
# binaries themselves: trivy
# evaluates each one's embedded Go build info, syft inventories which files
# ARE Go binaries, and the same union / second-opinion / blind rules as the
# image scan apply (GO BINARY COVERAGE in the header).
# -----------------------------------------------------------------------------
RFS_STATUS="skipped"; RFS_BINARIES=0; RFS_BY_TRIVY=0; RFS_BY_GRYPE=0; RFS_BLIND=0
RFS_FINDINGS=0; RFS_SUPPRESSED=0; RFS_BLOCKING=0; RFS_MISSING_EXPECTED=""
RFS_LIST="[]"
if [[ -n "$ROOTFS" ]]; then
  echo "=== Scanning root filesystem Go binaries: ${ROOTFS} ==="
  echo "  Expected Go binaries: ${ROOTFS_GO_EXPECTED}"
  _rb="${OUTPUT_DIR}/rootfs"; _rr="${_rb}.trivy.json"; _ri="${_rb}.syft.json"
  RFS_STATUS="ok"
  if ! trivy rootfs --scanners vuln --pkg-types library --severity "$SEVERITY" --list-all-pkgs \
         --format json --output "$_rr" "$ROOTFS" 2>"${_rb}.trivy.err" \
       || ! jq -e 'has("Results") or has("ArtifactName")' "$_rr" >/dev/null 2>&1; then
    echo "  ERROR: trivy could not scan ${ROOTFS} — NOT scanned, not clean"
    echo "         cause: $(grep -E 'FATAL|ERROR|error' "${_rb}.trivy.err" 2>/dev/null | tail -n1 | cut -c1-240)"
    RFS_STATUS="unscannable"; SCAN_BROKEN=true
  elif ! syft scan "dir:${ROOTFS}" --override-default-catalogers go-module-binary-cataloger \
           -o "syft-json=${_ri}" -q 2>"${_rb}.syft.err" \
       || ! jq -e 'has("artifacts")' "$_ri" >/dev/null 2>&1; then
    echo "  ERROR: could not inventory the Go binaries of ${ROOTFS} (syft) — trivy's coverage"
    echo "         of them cannot be asserted, so the root filesystem is NOT scanned, not clean"
    echo "         cause: $(tail -n1 "${_rb}.syft.err" 2>/dev/null | cut -c1-240)"
    RFS_STATUS="unscannable"; SCAN_BROKEN=true
  else
    _go_all=(); _missed=(); _gap=(); _blind=(); _evaluated=()
    mapfile -t _go_all < <(go_binary_inventory "$_ri")
    _go_trivy=$(trivy_go_targets "$_rr")
    for _x in ${_go_all[@]+"${_go_all[@]}"}; do
      grep -qxF -- "$_x" <<<"$_go_trivy" || _missed+=("$_x")
    done
    while IFS= read -r _x; do
      [[ -z "$_x" ]] && continue
      _evaluated+=("$_x")
      printf '%s\n' ${_go_all[@]+"${_go_all[@]}"} | grep -qxF -- "$_x" || _gap+=("$_x")
    done <<<"$_go_trivy"
    if [[ ${#_gap[@]} -gt 0 ]]; then
      echo "  WARN: INVENTORY GAP — trivy evaluated Go binar(ies) syft did not list: ${_gap[*]}"
    fi
    RFS_BINARIES=$(( ${#_go_all[@]} + ${#_gap[@]} ))
    RFS_BY_TRIVY=$(( ${#_go_all[@]} - ${#_missed[@]} + ${#_gap[@]} ))
    _g_n=0; _g_s=0; _g_b=0
    if [[ ${#_missed[@]} -gt 0 ]]; then
      echo "  WARN: trivy did NOT evaluate ${#_missed[@]} of ${#_go_all[@]} Go binar(ies): ${_missed[*]}"
      echo "        Second opinion (grype) for exactly those; the same policy applies."
      if second_opinion "$_ri" "${_rb}.grype.json" "${_missed[@]}"; then
        RFS_BY_GRYPE=${#_missed[@]}; _evaluated+=("${_missed[@]}")
        read -r _g_n _g_s _g_b < <(grype_policy "${_rb}.grype.json") || true
      else
        _blind+=("${_missed[@]}")
      fi
    fi
    RFS_BLIND=${#_blind[@]}
    if [[ "$RFS_BLIND" -gt 0 ]]; then
      echo "  ERROR: BLIND — ${RFS_BLIND} Go binar(ies) were evaluated by NO scanner:"
      printf '           %s\n' "${_blind[@]}"
      RFS_STATUS="blind"; SCAN_BROKEN=true
    fi
    # Coverage assertion: at least one Go binary, and every expected one.
    if [[ "$RFS_BINARIES" -eq 0 ]]; then
      echo "  ERROR: ZERO Go binaries found in ${ROOTFS} — a scan that evaluated nothing is not clean"
      RFS_STATUS="no-coverage"; SCAN_BROKEN=true
    fi
    for _e in $ROOTFS_GO_EXPECTED; do
      _hit=false
      for _x in ${_evaluated[@]+"${_evaluated[@]}"}; do
        [[ "$(basename "$_x")" == "$_e" ]] && { _hit=true; break; }
      done
      if [[ "$_hit" != "true" ]]; then RFS_MISSING_EXPECTED="${RFS_MISSING_EXPECTED:+${RFS_MISSING_EXPECTED} }${_e}"; fi
    done
    if [[ -n "$RFS_MISSING_EXPECTED" ]]; then
      echo "  ERROR: expected Go binar(ies) NOT among the evaluated ones: ${RFS_MISSING_EXPECTED}"
      echo "         Either the binary is gone from the image (then drop it from the expectation in"
      echo "         the same change), or the scanner no longer sees it — both must be said, not skipped."
      RFS_STATUS="no-coverage"; SCAN_BROKEN=true
    fi
    read -r _n _s < <(count_unsuppressed "$_rr") || true
    _b=0
    while IFS= read -r _id; do
      [[ -z "$_id" ]] && continue
      is_allowed "$_id" || _b=$((_b + 1))
    done < <(jq -r '[.Results[]?.Vulnerabilities // []] | flatten | .[]
                    | select(.Severity == "CRITICAL")
                    | select(((.FixedVersion // "") != "") or (.Status == "fixed"))
                    | .VulnerabilityID' "$_rr" 2>/dev/null | sort -u || true)
    RFS_FINDINGS=$((_n + _g_n)); RFS_SUPPRESSED=$((_s + _g_s)); RFS_BLOCKING=$((_b + _g_b))
    # One line per binary: what it carries, and what of it blocks under D1.
    jq -r '.Results[]? | select(.Type == "gobinary")
           | [.Target, ((.Packages // []) | length), ((.Vulnerabilities // []) | length),
              ([(.Vulnerabilities // [])[] | select(.Severity == "CRITICAL")
                | select(((.FixedVersion // "") != "") or (.Status == "fixed"))] | length)] | @tsv' "$_rr" 2>/dev/null \
      | awk -F'\t' '{printf "    %-40s %4s modules  %3s %s  %s fixable CRITICAL\n", $1, $2, $3, "finding(s)", $4}' || true
    if [[ "$RFS_FINDINGS" -gt 0 ]]; then
      jq -r '[.Results[]? | .Target as $t | (.Vulnerabilities // [])[]
              | [.Severity, .VulnerabilityID, .PkgName, (.InstalledVersion // "?"),
                 (if ((.FixedVersion // "") != "") then .FixedVersion else "none published" end), $t] | @tsv]
             | unique | .[]' "$_rr" 2>/dev/null \
        | awk -F'\t' '{printf "    %-8s %-20s %s %s -> %s  (%s)\n", $1, $2, $3, $4, $5, $6}' || true
    fi
    [[ "$RFS_STATUS" == "ok" && "$RFS_FINDINGS" -gt 0 ]] && RFS_STATUS="findings"
    [[ "$RFS_STATUS" == "ok" ]] && RFS_STATUS="clean"
    RFS_LIST=$(jq -c '[.Results[]? | select(.Type == "gobinary") | {binary: .Target,
                 modules: ((.Packages // []) | length), findings: ((.Vulnerabilities // []) | length)}]' "$_rr" 2>/dev/null || echo '[]')
  fi
  echo ""
  echo "=== Rootfs Go binary scan: ${RFS_BINARIES} Go binar(ies), ${RFS_BY_TRIVY} evaluated by trivy, ${RFS_BY_GRYPE} by grype, ${RFS_BLIND} by neither ==="
  echo "    ${RFS_FINDINGS} ${SEVERITY} finding(s)$([[ "$RFS_SUPPRESSED" -gt 0 ]] && echo ", ${RFS_SUPPRESSED} allowlisted"); policy ${POLICY}: ${RFS_BLOCKING} fixable CRITICAL not allowlisted"
fi

# -----------------------------------------------------------------------------
# OS SBOM scanning
#
# The verdict is only believed if the scanner demonstrably evaluated the
# components. `--list-all-pkgs` makes trivy report every package it considered;
# comparing that against the SBOM component count is an exact coverage measure.
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# Per-package coverage of the GA defconfig delta (--package-coverage).
#
# The SBOM scan reports a coverage PERCENTAGE. A percentage hides which package
# is blind, and the packages GA adds itself are the ones nobody upstream
# watches: measured 2026-07-28, netbird, telegraf and nftables carried no CPE at
# all. So every BR2_PACKAGE_*=y the GA defconfig adds on top of the upstream
# one must be classified in COVERAGE_CONF, by HOW it is covered:
#   nvd       carries a CPE that matched >= 1 NVD entry (ga:nvd-matches)
#   go        a Go binary, covered by the rootfs scan (--rootfs); its name must
#             be one of ROOTFS_GO_EXPECTED
#   upstream  NVD has no product for it (checked, dated, in the note); covered
#             only by the upstream release/advisory watcher in the ops repo
#   option    a sub-option of another package, not code of its own
#   config    GA configuration files only, no upstream code
# Anything else fails the scan as BROKEN: an unclassified new package, a
# classified one that is missing from the SBOM, an `nvd` package that matched
# nothing (a wrong CPE looks exactly like a clean package), a delta the parser
# could not read, or a classification without a note where one is required.
# -----------------------------------------------------------------------------
PKGCOV_EXPECTED=0; PKGCOV_COVERED=0; PKGCOV_BROKEN=0
PKGCOV_LIST_FILE=/dev/null
check_package_coverage() {
  local sbom="$1" sym comp mode note line n br cpe matches
  PKGCOV_LIST_FILE="${OUTPUT_DIR}/package-coverage.jsonl"; : > "$PKGCOV_LIST_FILE"
  echo ""
  echo "  --- Per-package coverage: GA defconfig delta ---"
  local bad=0
  for f in "$COVERAGE_CONF" "$GA_DEFCONFIG" "$BASE_DEFCONFIG"; do
    [[ -f "$f" ]] || { echo "  ERROR: ${f} not found — the package coverage cannot be asserted"; bad=1; }
  done
  if [[ "$bad" -ne 0 ]]; then PKGCOV_BROKEN=1; SCAN_BROKEN=true; return 0; fi
  local delta=()
  mapfile -t delta < <(comm -23 \
      <(sed -nE 's/^BR2_PACKAGE_([A-Z0-9_]+)=y[[:space:]]*$/\1/p' "$GA_DEFCONFIG" | sort -u) \
      <(sed -nE 's/^BR2_PACKAGE_([A-Z0-9_]+)=y[[:space:]]*$/\1/p' "$BASE_DEFCONFIG" | sort -u))
  echo "  GA-added package symbols: ${#delta[@]} ($(basename "$GA_DEFCONFIG") minus $(basename "$BASE_DEFCONFIG"))"
  local must
  for must in $COVERAGE_MUST_SEE; do
    if ! printf '%s\n' ${delta[@]+"${delta[@]}"} | grep -qxF -- "$must"; then
      echo "  ERROR: the delta parser did not find BR2_PACKAGE_${must} — it has lost its subject"
      PKGCOV_BROKEN=$((PKGCOV_BROKEN + 1))
    fi
  done
  for sym in ${delta[@]+"${delta[@]}"}; do
    PKGCOV_EXPECTED=$((PKGCOV_EXPECTED + 1))
    line=$(awk -v s="$sym" '$1 !~ /^#/ && $1 == s {print; exit}' "$COVERAGE_CONF")
    if [[ -z "$line" ]]; then
      echo "    BLIND    ${sym}: not classified in $(basename "$COVERAGE_CONF") — say how this package is covered"
      PKGCOV_BROKEN=$((PKGCOV_BROKEN + 1))
      jq -cn --arg s "$sym" '{symbol:$s, state:"unclassified"}' >> "$PKGCOV_LIST_FILE"
      continue
    fi
    read -r _ comp mode note <<<"$line"
    local state="covered" why=""
    case "$mode" in
      nvd|go)
        # The component must be in the SBOM as a SHIPPED package.
        n=$(jq -r --arg c "$comp" '[.components[]? | select(.name == $c)
               | select(((.properties // []) | map(select(.name=="BR_TYPE").value) | first) == "target")] | length' "$sbom" 2>/dev/null || echo 0)
        if [[ "${n:-0}" -eq 0 ]]; then
          state="blind"; why="no shipped component '${comp}' in the SBOM"
        elif [[ "$mode" == "nvd" ]]; then
          cpe=$(jq -r --arg c "$comp" '[.components[]? | select(.name == $c) | .cpe // empty] | first // empty' "$sbom" 2>/dev/null || true)
          matches=$(jq -r --arg c "$comp" '[.components[]? | select(.name == $c)
                      | (.properties // [])[] | select(.name == "ga:nvd-matches") | .value | tonumber] | max // empty' "$sbom" 2>/dev/null || true)
          if [[ -z "$cpe" ]]; then state="blind"; why="no CPE — cve-check cannot match it"
          elif [[ -z "$matches" ]]; then state="blind"; why="no ga:nvd-matches count — the SBOM was not annotated (sbom-cve-annotate.py)"
          elif [[ "$matches" -lt 1 ]]; then state="blind"; why="CPE ${cpe} matched 0 NVD entries — wrong vendor/product, or NVD has none"
          else why="CPE matched ${matches} NVD entr$([[ "$matches" -eq 1 ]] && echo y || echo ies)"; fi
        else
          if [[ " ${ROOTFS_GO_EXPECTED} " == *" ${comp} "* ]]; then why="Go binary, asserted by the rootfs scan"
          else state="blind"; why="classified 'go' but '${comp}' is not an expected binary of the rootfs scan"; fi
        fi ;;
      upstream|option|config)
        if [[ -z "${note// /}" ]]; then state="blind"; why="classified '${mode}' without a note saying why"
        else why="${mode}: ${note}"; fi ;;
      *) state="blind"; why="unknown coverage mode '${mode}'" ;;
    esac
    if [[ "$state" == "covered" ]]; then
      PKGCOV_COVERED=$((PKGCOV_COVERED + 1)); echo "    covered  ${sym} (${comp}) — ${why}"
    else
      PKGCOV_BROKEN=$((PKGCOV_BROKEN + 1)); echo "    BLIND    ${sym} (${comp}) — ${why}"
    fi
    jq -cn --arg s "$sym" --arg c "$comp" --arg m "$mode" --arg st "$state" --arg w "$why" \
       '{symbol:$s, component:$c, mode:$m, state:$st, detail:$w}' >> "$PKGCOV_LIST_FILE"
  done
  echo "  Package coverage: ${PKGCOV_COVERED}/${PKGCOV_EXPECTED} GA-added package symbol(s) covered"
  if [[ "${#delta[@]}" -eq 0 ]]; then
    echo "  ERROR: the GA defconfig delta is EMPTY — nothing was checked, which is not coverage"
    PKGCOV_BROKEN=$((PKGCOV_BROKEN + 1))
  fi
  if [[ "$PKGCOV_BROKEN" -gt 0 ]]; then
    echo "  ERROR: ${PKGCOV_BROKEN} GA-added package(s) or parser condition(s) without coverage — BROKEN, not clean"
    SCAN_BROKEN=true
  fi
  return 0
}

SBOM_COMPONENTS=0; SBOM_SCANNED=0; SBOM_COVERAGE=0; SBOM_FINDINGS=0; SBOM_SUPPRESSED=0; SBOM_TRACKED=0; SBOM_HOSTONLY=0
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
      # ---------------------------------------------------------------------
      # Classify each exploitable finding by DEVICE ATTACK SURFACE (see
      # docs/CVE-SCANNING-POSTURE.md / KB). The fatal count is GATE only.
      #   GATE    — a SHIPPED (BR_TYPE=target) userland package that is NOT the
      #             kernel or the bootloader. Per-build actionable (bump the
      #             package or time-box an allowlist entry), so it stays fatal.
      #   TRACK   — the kernel ("linux") or bootloader ("uboot*"): shipped, but
      #             monolithic firmware that no per-build package bump can fix.
      #             Governed by a kernel/bootloader VERSION POLICY + periodic
      #             triage, not a per-build hard-fail — an embedded kernel always
      #             carries HIGH CVEs, and a zero-tolerance gate against a LIVE
      #             CVE database flips the SAME artefact red the moment the db
      #             updates (that is what happened between rc25 and rc26/rc27).
      #             Reported and written out for triage, never silently dropped.
      #   EXCLUDE — the only affected components are host/build-time tools that
      #             are NOT installed on the device: no device attack surface.
      # ---------------------------------------------------------------------
      # D1 inside GATE: a CRITICAL with a fixed upstream version BLOCKS; HIGH,
      # and CRITICAL without a fix, are reported. Severity = the highest rating
      # any source gave (NVD primary or CNA). The fix is the `ga:fixed-in`
      # property sbom-cve-annotate.py wrote from the NVD entry; "?" (no
      # property) is treated as fixable — a gate that cannot tell must not
      # assume the harmless answer.
      SBOM_FINDINGS=0; SBOM_SUPPRESSED=0; SBOM_TRACKED=0; SBOM_HOSTONLY=0; SBOM_BLOCKING=0
      TRACK_FILE="${OUTPUT_DIR}/os-tracked-cves.txt"; : > "$TRACK_FILE"
      while IFS=' ' read -r _id _class _vsev _fix _pkgs; do
        [[ -z "$_id" ]] && continue
        case "$_class" in
          GATE)
            if is_allowed "$_id"; then SBOM_SUPPRESSED=$((SBOM_SUPPRESSED + 1))
            else
              SBOM_FINDINGS=$((SBOM_FINDINGS + 1))
              if [[ "$_vsev" == "CRITICAL" && "$_fix" != "none" ]]; then
                SBOM_BLOCKING=$((SBOM_BLOCKING + 1))
                echo "    GATE     ${_id} ${_vsev} ${_pkgs} fixed-in ${_fix}$([[ "$_fix" == "?" ]] && echo ' (fix data missing: treated as fixable)') — BLOCKS (D1)"
              else
                echo "    GATE     ${_id} ${_vsev} ${_pkgs} fixed-in ${_fix} — reported"
              fi
            fi ;;
          TRACK)   SBOM_TRACKED=$((SBOM_TRACKED + 1)); printf '%s\n' "$_id" >> "$TRACK_FILE" ;;
          *)       SBOM_HOSTONLY=$((SBOM_HOSTONLY + 1)) ;;
        esac
      done < <(jq -r --arg sev "$_sev_re" '
                 (reduce (.components[]?) as $c ({};
                    . + {($c["bom-ref"] // "?"): {n:($c.name // "?"),
                         br:(($c.properties // [] | map(select(.name=="BR_TYPE").value) | first) // "?")}})) as $m
                 | [ .vulnerabilities // [] | .[]
                     | select(.analysis.state == "exploitable")
                     | select([.ratings // [] | .[] | .severity // ""] | any(test($sev)))
                     | . as $v
                     | ([ $v.affects[]?.ref | ($m[.] // {n:"?",br:"?"}) ]) as $comps
                     | ($comps | map(select(.br == "target"))) as $ship
                     | ($ship | map(select(.n != "linux" and (.n | startswith("uboot") | not)))) as $userland
                     | ([$v.ratings // [] | .[] | .severity // "" | ascii_downcase
                         | {"critical":4,"high":3,"medium":2,"low":1}[.] // 0] | max // 0) as $rank
                     | { id:$v.id,
                         class:(if ($userland | length) > 0 then "GATE"
                                elif ($ship | length) > 0 then "TRACK"
                                elif (($comps | length) > 0) and ($comps | all(.br == "host")) then "EXCLUDE"
                                else "GATE" end),
                         sev:({"4":"CRITICAL","3":"HIGH","2":"MEDIUM","1":"LOW"}[$rank|tostring] // "UNKNOWN"),
                         fix:([$v.properties // [] | .[] | select(.name == "ga:fixed-in") | .value] | first // "?"),
                         pkgs:(([$userland[].n] | unique | join(",")) | if . == "" then "-" else . end) } ]
                 | unique_by(.id) | .[] | "\(.id) \(.class) \(.sev) \(.fix) \(.pkgs)"' "$GA_SBOM" 2>/dev/null || true)
      [[ "$SBOM_TRACKED"  -gt 0 ]] && echo "  TRACKED: ${SBOM_TRACKED} kernel/bootloader finding(s) -> ${TRACK_FILE} — version policy + periodic triage, not a per-build block (see docs/CVE-SCANNING-POSTURE.md)"
      [[ "$SBOM_HOSTONLY" -gt 0 ]] && echo "  EXCLUDED: ${SBOM_HOSTONLY} finding(s) affecting only host/build-time packages — not shipped on the device"
      if [[ "$PACKAGE_COVERAGE" == "true" ]]; then check_package_coverage "$GA_SBOM"; fi

      if [[ "$SBOM_COVERAGE" -lt "$COVERAGE_MIN_PCT" ]]; then
        echo "  ERROR: only ${SBOM_COVERAGE}% of SBOM components carry a matchable CPE (minimum ${COVERAGE_MIN_PCT}%)"
        SBOM_STATUS="no-coverage"
        SCAN_BROKEN=true
      elif [[ "$SBOM_FINDINGS" -gt 0 ]]; then
        echo "  FOUND: ${SBOM_FINDINGS} exploitable ${SEVERITY} vulnerabilities in shipped userland$([[ "$SBOM_SUPPRESSED" -gt 0 ]] && echo ", ${SBOM_SUPPRESSED} allowlisted"); D1 blocking (CRITICAL with a fix): ${SBOM_BLOCKING}"
        SBOM_STATUS="findings"
        if [[ "$POLICY" == "d1" && "$SBOM_BLOCKING" -gt 0 ]]; then EXIT_CODE=1; fi
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
    echo "        (run a build first: ./scripts/ga_build.sh)"
    SBOM_STATUS="missing"
    # As a gate (--strict) a missing SBOM is a failure, not a skip.
    if [[ "$STRICT" == "true" ]]; then
      echo "  ERROR: --strict requires an SBOM — refusing to report success without one"
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
  --argjson sbom_tracked "${SBOM_TRACKED:-0}" \
  --argjson sbom_hostonly "${SBOM_HOSTONLY:-0}" \
  --argjson img_total "${IMG_TOTAL:-0}" \
  --argjson img_clean "${IMG_PASS:-0}" \
  --argjson img_with "${IMG_FAIL:-0}" \
  --argjson img_blind "${IMG_BLIND:-0}" \
  --argjson img_unscannable "${img_unscannable:-0}" \
  --argjson img_findings "${IMG_FINDINGS:-0}" \
  --argjson img_suppressed "${IMG_SUPPRESSED:-0}" \
  --argjson img_blocking "${IMG_BLOCKING:-0}" \
  --argjson img_blocked "${IMG_BLOCKED:-0}" \
  --argjson go_bin "${GO_BINARIES:-0}" \
  --argjson go_trivy "${GO_BY_TRIVY:-0}" \
  --argjson go_grype "${GO_BY_GRYPE:-0}" \
  --argjson go_blind "${GO_BLIND:-0}" \
  --argjson go_gap "${GO_INVENTORY_GAP:-0}" \
  --arg img_source "${IMG_SOURCE:-none}" \
  --arg policy "$POLICY" \
  --argjson allow_expired "${allow_expired:-0}" \
  --argjson allow_invalid "${allow_invalid:-0}" \
  --slurpfile img_list "$IMG_LIST_FILE" \
  --argjson sbom_blocking "${SBOM_BLOCKING:-0}" \
  --argjson pkgcov_expected "${PKGCOV_EXPECTED:-0}" \
  --argjson pkgcov_covered "${PKGCOV_COVERED:-0}" \
  --argjson pkgcov_broken "${PKGCOV_BROKEN:-0}" \
  --argjson pkgcov_on "$([[ "$PACKAGE_COVERAGE" == "true" ]] && echo true || echo false)" \
  --slurpfile pkgcov_list "$PKGCOV_LIST_FILE" \
  --arg rfs_status "$RFS_STATUS" \
  --arg rfs_dir "${ROOTFS:-}" \
  --arg rfs_expected "$ROOTFS_GO_EXPECTED" \
  --arg rfs_missing "${RFS_MISSING_EXPECTED:-}" \
  --argjson rfs_bin "${RFS_BINARIES:-0}" \
  --argjson rfs_trivy "${RFS_BY_TRIVY:-0}" \
  --argjson rfs_grype "${RFS_BY_GRYPE:-0}" \
  --argjson rfs_blind "${RFS_BLIND:-0}" \
  --argjson rfs_findings "${RFS_FINDINGS:-0}" \
  --argjson rfs_suppressed "${RFS_SUPPRESSED:-0}" \
  --argjson rfs_blocking "${RFS_BLOCKING:-0}" \
  --argjson rfs_list "${RFS_LIST:-[]}" \
  '{date:$date, severity:$severity, strict:$strict, policy:$policy, scan_broken:$broken,
    allowlist_expired:$allow_expired, allowlist_invalid:$allow_invalid,
    os:{status:$sbom_status, components:$sbom_components, scanned:$sbom_scanned,
        coverage_pct:$sbom_coverage, findings:$sbom_findings, suppressed:$sbom_suppressed,
        tracked:$sbom_tracked, host_only:$sbom_hostonly, blocking:$sbom_blocking,
        package_coverage:{checked:$pkgcov_on, expected:$pkgcov_expected, covered:$pkgcov_covered,
                          broken:$pkgcov_broken, list:$pkgcov_list}},
    rootfs:{status:$rfs_status, dir:$rfs_dir, go_binaries:$rfs_bin, by_trivy:$rfs_trivy,
            by_grype:$rfs_grype, blind:$rfs_blind, expected:($rfs_expected | split(" ") | map(select(length > 0))),
            missing_expected:($rfs_missing | split(" ") | map(select(length > 0))),
            findings:$rfs_findings, suppressed:$rfs_suppressed, blocking:$rfs_blocking, list:$rfs_list},
    images:{source:$img_source, total:$img_total, clean:$img_clean, with_findings:$img_with,
            blind:$img_blind, unscannable:$img_unscannable, findings:$img_findings,
            suppressed:$img_suppressed, blocking:$img_blocking, blocked_images:$img_blocked,
            go_binaries:{inventoried:$go_bin, by_trivy:$go_trivy, by_grype:$go_grype, blind:$go_blind, inventory_gap:$go_gap},
            list:$img_list}}' \
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

# Rootfs policy (D1): the same rule as the images. Whether the BUILD stops on
# it is decided at the call site (ga_build.sh, scripts/cve-enforcement.conf).
if [[ "$POLICY" == "d1" && "${RFS_BLOCKING:-0}" -gt 0 ]]; then
  echo "  Result: POLICY BLOCK — ${RFS_BLOCKING} fixable CRITICAL finding(s) in the root filesystem's Go binaries (exit 1)"
  echo "          Update the package, or add a time-boxed entry (reason, <= ${ALLOW_MAX_DAYS} days) to ${ALLOW_FILE}."
  exit 1
fi

# Image policy (D1): a fixable CRITICAL that no valid allowlist entry covers
# blocks, whatever --strict says — --strict governs the OS half only.
if [[ "$POLICY" == "d1" && "${IMG_BLOCKING:-0}" -gt 0 ]]; then
  echo "  Result: POLICY BLOCK — ${IMG_BLOCKING} fixable CRITICAL finding(s) in ${IMG_BLOCKED} image(s) (exit 1)"
  echo "          Update the image, or add a time-boxed entry (reason, <= ${ALLOW_MAX_DAYS} days) to ${ALLOW_FILE}."
  exit 1
fi

if [[ "$EXIT_CODE" -ne 0 ]]; then
  if [[ "$STRICT" == "true" ]]; then
    echo "  Result: POLICY BLOCK — ${SBOM_BLOCKING:-0} fixable CRITICAL finding(s) in shipped OS packages, strict mode (exit 1)"
    exit 1
  fi
  echo "  Result: findings above budget — reporting only (strict=false), exit 0"
  echo "          Triage them into ${ALLOW_FILE} or fix them, then enable --strict."
  exit 0
fi

echo "  Result: OK (exit 0)"
exit 0
