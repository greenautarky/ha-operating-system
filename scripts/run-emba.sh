#!/usr/bin/env bash
# run-emba.sh — binary-level firmware analysis of a built GA OS image.
#
# WHY THIS EXISTS
# ---------------
# Our CVE pipeline matches package metadata: Buildroot's cve-check maps each
# SBOM component's `cpe` against NVD. Measured 2026-07-28, that reaches ~69% of
# SHIPPED packages and no further — NVD simply has no CPE for most of the rest
# (18-20 of the 26 checked), and several that look like matches are different
# products entirely (`nftables` -> `google:nftables` is the Go library, not
# netfilter; `libxcrypt` -> `elektrobit:libxcrypt` is an unrelated vendor).
#
# So the remaining ~30% is NOT closable with more metadata. EMBA analyses the
# built binaries themselves and needs no CPE at all, which makes it the primary
# coverage path for those packages rather than a nice-to-have. It also finds a
# class this pipeline cannot see regardless of coverage: missing binary
# hardening (NX/PIE/RELRO/canaries), hardcoded credentials, weak service
# configuration, and world-writable or setuid files.
#
# RUNS ON THE BUILD HOST, NOT INSIDE THE BAKE
# -------------------------------------------
# EMBA needs its own privileged container with /dev/fuse and SYS_ADMIN, and a
# full EMBA checkout bind-mounted at /emba (the published image carries the
# dependencies, NOT the EMBA scripts — a detail that is easy to get wrong).
# Wiring that into the bake container would mean docker-in-docker for no gain.
# This is a post-build analysis step: it consumes the release artifact.
#
# NOT A BUILD GATE (yet)
# ----------------------
# A full EMBA scan takes hours. Gating a bake on it would make the pipeline
# unusable and the gate would be switched off within a week — the same failure
# mode the CVE allowlist exists to prevent. Report first, archive per release,
# and gate later on specific finding classes once we know the baseline.
#
# SETUP (once, on the build host):
#   git clone https://github.com/e-m-b-a/emba.git "$GA_EMBA_DIR"
#   cd "$GA_EMBA_DIR" && sudo ./installer.sh -d      # -d = docker/dependency mode
#
# Usage:
#   ./scripts/run-emba.sh [--image <path>] [--profile <name>] [--log <dir>]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GA_EMBA_DIR="${GA_EMBA_DIR:-/home/builder/emba}"
IMAGE=""
PROFILE="${GA_EMBA_PROFILE:-default-scan.emba}"
LOGDIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)   IMAGE="$2";   shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --log)     LOGDIR="$2";  shift 2 ;;
    --emba)    GA_EMBA_DIR="$2"; shift 2 ;;
    --help|-h) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# --- Locate the artifact ------------------------------------------------------
# Prefer the compressed release image: it is what actually ships, and letting
# EMBA do its own extraction exercises the path a third party would take.
if [[ -z "$IMAGE" ]]; then
  IMAGE="$(ls -t "${REPO_ROOT}"/ga_output/images/*.img.xz 2>/dev/null | head -1 || true)"
  [[ -n "$IMAGE" ]] || IMAGE="$(ls -t "${REPO_ROOT}"/ga_output/images/*.img 2>/dev/null | head -1 || true)"
fi
if [[ -z "$IMAGE" || ! -f "$IMAGE" ]]; then
  echo "ERROR: no image found. Build one first (./scripts/ga_build.sh update prod)"
  echo "       or pass --image <path>."
  exit 2
fi

if [[ ! -x "${GA_EMBA_DIR}/emba" ]]; then
  cat >&2 <<EOF
ERROR: no EMBA checkout at ${GA_EMBA_DIR}

EMBA's published container holds the dependencies but NOT the EMBA scripts —
they are bind-mounted from the host. One-time setup:

  git clone https://github.com/e-m-b-a/emba.git ${GA_EMBA_DIR}
  cd ${GA_EMBA_DIR} && sudo ./installer.sh -d

Override the location with --emba <dir> or GA_EMBA_DIR.
EOF
  exit 2
fi

BUILD_ID="$(basename "$IMAGE" | sed 's/\.img\(\.xz\)\?$//')"
LOGDIR="${LOGDIR:-${REPO_ROOT}/ga_output/emba/${BUILD_ID}}"
mkdir -p "$LOGDIR"

# --- Share the NVD mirror with Buildroot's cve-check --------------------------
# Both want a clone of fkie-cad/nvd-json-data-feeds, which is multi-GB. Point
# EMBA at the one the bake already maintains instead of cloning it twice.
BR_NVD="${REPO_ROOT}/buildroot/dl/buildroot-nvd"
EMBA_NVD="${GA_EMBA_DIR}/external/nvd-json-data-feeds"
if [[ -d "$BR_NVD" && ! -e "$EMBA_NVD" ]]; then
  mkdir -p "$(dirname "$EMBA_NVD")"
  ln -s "$BR_NVD" "$EMBA_NVD"
  echo "Linked EMBA's NVD feed to the bake's mirror: ${EMBA_NVD} -> ${BR_NVD}"
fi

echo "=== EMBA firmware analysis ==="
echo "  Image:   ${IMAGE}"
echo "  Profile: ${PROFILE}"
echo "  Logs:    ${LOGDIR}"
echo "  EMBA:    ${GA_EMBA_DIR}"
echo ""
echo "  This takes HOURS. It is a post-build analysis, not a gate."
echo ""

# EMBA's own wrapper handles the privileged container, /dev/fuse and the
# bind mounts; -D selects docker mode. Reproducing that by hand is how the
# mounts drift out of sync with upstream.
_rc=0
set +e
( cd "$GA_EMBA_DIR" && sudo ./emba -D \
    -f "$IMAGE" \
    -l "$LOGDIR" \
    -p "./scan-profiles/${PROFILE}" )
_rc=$?
set -e

# --- Verify the run produced something, rather than trusting the exit code ----
# Same rule as the CVE scan: a tool that silently analysed nothing must not read
# as a clean result. EMBA writes its HTML report and a CSV summary under $LOGDIR.
REPORT="${LOGDIR}/html-report/index.html"
if [[ ! -s "$REPORT" ]]; then
  echo ""
  echo "ERROR: EMBA exited ${_rc} but produced no HTML report at ${REPORT}"
  echo "       Treat this as a BROKEN ANALYSIS, not a clean one."
  exit 2
fi

echo ""
echo "=== EMBA complete (exit ${_rc}) ==="
echo "  Report: ${REPORT}"
[[ -f "${LOGDIR}/f50_base_aggregator.txt" ]] && {
  echo "  --- aggregator summary ---"
  grep -E "^\[\*\]" "${LOGDIR}/f50_base_aggregator.txt" 2>/dev/null | head -30 | sed 's/^/    /'
}
exit 0
