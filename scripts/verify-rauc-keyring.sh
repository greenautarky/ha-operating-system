#!/usr/bin/env bash
# verify-rauc-keyring.sh — assert WHAT IS ACTUALLY IN the RAUC keyring of a build
#
# Usage:
#   ./scripts/verify-rauc-keyring.sh <output_dir>     # e.g. ga_output (has target/)
#   ./scripts/verify-rauc-keyring.sh --print <pem>    # dump fingerprints of a bundle
#
# Exit codes (distinct on purpose, same convention as scan-cves.sh):
#   0  the shipped keyring holds exactly the expected trust anchors
#   1  findings: an extra / missing / wrong trust anchor   (fatal on prod)
#   2  the check itself could not run                      (ALWAYS fatal on prod)
#
# WHY THIS EXISTS
#   /etc/rauc/keyring.pem is the ONLY thing standing between a device and an
#   attacker-signed OTA. It is assembled at build time by three separate code
#   paths in buildroot-external/scripts/rauc.sh:
#     1. the base CA            — ota/rel-ca.pem (production) or dev-ca.pem
#     2. the local signing cert — appended SILENTLY whenever /build/cert.pem
#        does not verify against dev-ca.pem (i.e. on any machine that lacks the
#        real signing key, a self-signed cert becomes a fleet trust anchor)
#     3. the retired F13 CA     — appended when GA_LEGACY_CA_BRIDGE=true
#
#   Until this script, NOTHING asserted the RESULT. RAUC-LEGACY-01 exercises the
#   gate function against a scratch file, RAUC-LEGACY-02 only checks that the
#   flag is DECLARED in meta (not its value), and OTA-05 only checks that the
#   file EXISTS. All three stay green if a fourth certificate appears in the
#   shipped image. This script compares the artifact against its declared
#   inputs, by SHA-256 fingerprint, and fails on any difference in either
#   direction.
#
#   A wrong trust anchor is expensive to correct. The rootfs is a read-only
#   squashfs/erofs and /etc/rauc is NOT one of the paths bind-mounted from
#   /mnt/overlay (see usr/libexec/hassos-overlay), so it cannot be edited in
#   place; and `rauc install` verifies against the keyring the device already
#   runs, so the supported update path is exactly what a bad keyring blocks.
#   What remains is a manual raw write to the inactive slot over SSH, once per
#   device (see docs/RAUC-KEYRING.md) — bounded, but reachability-dependent and
#   per-device. Build time is the only cheap moment.
#
# Related: OS#241 (the GA_LEGACY_CA_BRIDGE gate), Odoo #624 (this audit),
#          Odoo #534 (fleet inventory — the blocker for dropping the bridge).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# The retired pre-2026-03-27 signing CA, pinned. Documented in rauc.sh; pinned
# here so swapping the file in-tree is a build failure, not a silent re-trust.

# Subject that scripts/generate-signing-key.sh stamps on a throwaway dev key.
DEV_SUBJECT_CN="HassOS Self-signed Development Certificate"

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' RESET='\033[0m'
[[ -t 1 ]] || { GREEN=''; RED=''; YELLOW=''; RESET=''; }
_ok()   { echo -e "  ${GREEN}OK${RESET}    $1"; }
_bad()  { echo -e "  ${RED}FAIL${RESET}  $1"; findings=$((findings+1)); }
_warn() { echo -e "  ${YELLOW}WARN${RESET}  $1"; warns=$((warns+1)); }

findings=0
warns=0

# ---------------------------------------------------------------------------
# cert_records <pem-bundle> -> "<sha256-fp>\t<subject>\t<notAfter>" per cert
#
# The bundle is NOT a clean PEM file: install_rauc_certs appends with
# `openssl x509 -text`, so human-readable blocks sit between the PEM armour.
# `openssl x509 -in <bundle>` would read only the FIRST certificate and report
# success — which is precisely how a smuggled-in trust anchor stays invisible.
# Split on the armour and fingerprint every block.
# ---------------------------------------------------------------------------
cert_records() {
  local bundle="$1" dir cert subj fp end
  dir="$(mktemp -d)" || return 2
  awk -v d="$dir" '
    /-----BEGIN CERTIFICATE-----/ { n++; f = sprintf("%s/c%04d.pem", d, n); inc = 1 }
    inc { print > f }
    /-----END CERTIFICATE-----/   { inc = 0 }
  ' "$bundle"
  for cert in "$dir"/c*.pem; do
    [[ -e "$cert" ]] || continue
    fp="$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')"
    subj="$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/^subject=*//')"
    end="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    [[ -n "$fp" ]] && printf '%s\t%s\t%s\n' "$fp" "$subj" "$end"
  done
  rm -rf "$dir"
}

fp_of_file() { cert_records "$1" | cut -f1 | head -1; }

# --print mode: inspect any bundle (a build's keyring, or one pulled off a
# device with `scp <dev>:/etc/rauc/keyring.pem`).
if [[ "${1:-}" == "--print" ]]; then
  [[ -f "${2:-}" ]] || { echo "usage: $0 --print <keyring.pem>" >&2; exit 2; }
  command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl not found" >&2; exit 2; }
  cert_records "$2" | while IFS=$'\t' read -r fp subj end; do
    printf '%s\n    subject: %s\n    expires: %s\n' "$fp" "$subj" "$end"
  done
  exit 0
fi

OUT="${1:?Usage: $0 <output_dir>   (or --print <keyring.pem>)}"
# Accept either the build output dir (has target/) or the target dir itself.
TARGET="${OUT}/target"
[[ -d "$TARGET" ]] || TARGET="$OUT"
KEYRING="${TARGET}/etc/rauc/keyring.pem"
OTA_DIR="${REPO_ROOT}/buildroot-external/ota"
META="${REPO_ROOT}/buildroot-external/meta"

echo ""
echo "=== RAUC keyring audit ==="
echo "  Keyring: $KEYRING"

command -v openssl >/dev/null 2>&1 \
  || { echo "  ERROR: openssl not found — cannot verify the keyring" >&2; exit 2; }
[[ -f "$META" ]] \
  || { echo "  ERROR: no buildroot-external/meta under ${REPO_ROOT}" >&2; exit 2; }
if [[ ! -f "$KEYRING" ]]; then
  echo "  ERROR: no keyring at ${KEYRING} — build output missing or rauc.sh did not run" >&2
  exit 2
fi

# --- declared inputs ------------------------------------------------------
DEPLOYMENT="$(sed -n 's/^DEPLOYMENT="\?\([^"]*\)"\?.*/\1/p' "$META" | head -1)"
: "${DEPLOYMENT:=production}"
: "${LEGACY_GATE:=unset}"
GA_ENV="${GA_ENV:-dev}"

if [[ "$DEPLOYMENT" == "development" ]]; then
  BASE_CA="${OTA_DIR}/dev-ca.pem"
else
  BASE_CA="${OTA_DIR}/rel-ca.pem"
fi

echo "  Deployment: ${DEPLOYMENT}   GA_ENV: ${GA_ENV}   retired-CA bridge: removed 2026-07-30"
echo ""

# rel-ca.pem / dev-ca.pem are gitignored — they live on the build server only.
# Without the base CA the expected set is unknowable, so refuse rather than
# guess: a check that silently drops its baseline is the bug we are fixing.
[[ -f "$BASE_CA" ]] \
  || { echo "  ERROR: base CA ${BASE_CA} not found — cannot derive the expected set" >&2; exit 2; }

declare -A EXPECTED_LABEL=()
while IFS=$'\t' read -r fp _subj _end; do
  [[ -n "$fp" ]] && EXPECTED_LABEL["$fp"]="base CA ($(basename "$BASE_CA"))"
done < <(cert_records "$BASE_CA")

# --- the shipped set ------------------------------------------------------
shipped_total=0
declare -A SHIPPED_SUBJ=() SHIPPED_END=()
while IFS=$'\t' read -r fp subj end; do
  [[ -n "$fp" ]] || continue
  shipped_total=$((shipped_total+1))
  SHIPPED_SUBJ["$fp"]="$subj"
  SHIPPED_END["$fp"]="$end"
done < <(cert_records "$KEYRING")

if (( shipped_total == 0 )); then
  echo "  ERROR: no certificate parsed out of ${KEYRING} — keyring is empty or malformed" >&2
  exit 2
fi

echo "  Trust anchors in the shipped keyring: ${#SHIPPED_SUBJ[@]} distinct (${shipped_total} blocks)"
for fp in "${!SHIPPED_SUBJ[@]}"; do
  printf '    %s\n      %s   (expires %s)\n' "$fp" "${SHIPPED_SUBJ[$fp]}" "${SHIPPED_END[$fp]}"
done
echo ""

# --- KEYRING-02: no anchor beyond the declared inputs ---------------------
extra=0
for fp in "${!SHIPPED_SUBJ[@]}"; do
  [[ -n "${EXPECTED_LABEL[$fp]:-}" ]] && continue
  extra=$((extra+1))
  if [[ "${SHIPPED_SUBJ[$fp]}" == *"$DEV_SUBJECT_CN"* && "$GA_ENV" != "prod" ]]; then
    _warn "KEYRING-02: dev build trusts a locally generated signing cert (${fp}) — expected without the real key, NEVER acceptable on prod"
  else
    _bad "KEYRING-02: UNDECLARED trust anchor in the shipped keyring: ${fp} — '${SHIPPED_SUBJ[$fp]}'"
  fi
done
(( extra == 0 )) && _ok "KEYRING-02: no trust anchor beyond the declared build inputs"

# --- KEYRING-03: every declared input actually landed ---------------------
missing=0
for fp in "${!EXPECTED_LABEL[@]}"; do
  if [[ -z "${SHIPPED_SUBJ[$fp]:-}" ]]; then
    missing=$((missing+1))
    _bad "KEYRING-03: declared anchor MISSING from the shipped keyring: ${fp} — ${EXPECTED_LABEL[$fp]}"
  fi
done
(( missing == 0 )) && _ok "KEYRING-03: every declared anchor is present in the shipped keyring"

# --- KEYRING-06: the retired CA bridge must be GONE, not merely off --------
# Until 2026-07-30 this checked that GA_LEGACY_CA_BRIDGE was not "true" on a prod
# build. That was a guard around a flag, with the retired cert still sitting next
# to it in the tree — one line from re-trusting a non-revocable CA:TRUE root
# valid to 2035, on every device, with no revocation path.
#
# Operator decision 2026-07-30: hard cut. The remaining pre-cut devices are being
# swapped, not bridged, so the flag, the cert and the bake function were deleted.
# This check now asserts that ABSENCE, which is a stronger property than "the
# flag says false": re-introducing the bridge has to reintroduce all three parts
# and delete this check, and that is not something anyone does by accident.
#
# Bridge-FORWARD is unaffected and deliberately preserved: signing a NEW image
# with the OLD KEY (archived off the builder, not destroyed) never required the
# retired cert to be in anybody's keyring.
_bridge_residue=""
[[ -f "${OTA_DIR}/legacy-signing-cert.pem" ]] && _bridge_residue+="ota/legacy-signing-cert.pem "
grep -q '^GA_LEGACY_CA_BRIDGE=' "$META" 2>/dev/null && _bridge_residue+="GA_LEGACY_CA_BRIDGE-in-meta "
grep -rq 'function add_legacy_ca_if_enabled' "$(dirname "$META")/scripts" 2>/dev/null && _bridge_residue+="add_legacy_ca_if_enabled() "
if [[ -z "$_bridge_residue" ]]; then
  _ok "KEYRING-06: retired CA bridge fully removed (no cert, no flag, no bake function)"
else
  _bad "KEYRING-06: retired CA bridge RESIDUE present: ${_bridge_residue}— the 2026-07-30 hard cut is incomplete, and a one-line change re-trusts a CA with no revocation path"
fi

# --- KEYRING-05: an expired anchor bricks OTA for the whole fleet ---------
now_s=$(date +%s)
for fp in "${!SHIPPED_END[@]}"; do
  end_s=$(date -d "${SHIPPED_END[$fp]}" +%s 2>/dev/null) || continue
  days=$(( (end_s - now_s) / 86400 ))
  if (( days < 0 )); then
    _bad "KEYRING-05: trust anchor EXPIRED ${days#-} days ago: ${fp} — OTA verification will fail"
  elif (( days < 365 )); then
    _warn "KEYRING-05: trust anchor expires in ${days} days: ${fp} — plan the rotation (it needs a bridge release)"
  fi
done

echo ""
echo "  Results: ${findings} finding(s), ${warns} warning(s)"
if (( findings > 0 )); then
  echo ""
  echo "  A keyring finding is not cosmetic: the trust set ships read-only in the"
  echo "  rootfs, and 'rauc install' verifies against the keyring the device already"
  echo "  runs — so the supported update path is what a bad keyring blocks. Correcting"
  echo "  it means a manual raw slot write per device. See docs/RAUC-KEYRING.md."
  exit 1
fi
echo "=== RAUC keyring audit passed ==="
exit 0
