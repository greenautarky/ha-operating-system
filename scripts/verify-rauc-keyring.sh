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
LEGACY_FP_PINNED="01:E7:CE:81:49:6B:75:43:22:3C:8B:31:29:4C:78:AB:D3:02:7F:FE:62:7A:B5:B6:28:AF:73:83:E1:21:BC:F7"

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
LEGACY_GATE="$(sed -n 's/^GA_LEGACY_CA_BRIDGE="\?\([^"]*\)"\?.*/\1/p' "$META" | head -1)"
: "${DEPLOYMENT:=production}"
: "${LEGACY_GATE:=unset}"
GA_ENV="${GA_ENV:-dev}"

if [[ "$DEPLOYMENT" == "development" ]]; then
  BASE_CA="${OTA_DIR}/dev-ca.pem"
else
  BASE_CA="${OTA_DIR}/rel-ca.pem"
fi
LEGACY_CERT="${OTA_DIR}/legacy-signing-cert.pem"

echo "  Deployment: ${DEPLOYMENT}   GA_ENV: ${GA_ENV}   GA_LEGACY_CA_BRIDGE: ${LEGACY_GATE}"
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

legacy_fp=""
if [[ "$LEGACY_GATE" == "true" ]]; then
  if [[ -f "$LEGACY_CERT" ]]; then
    legacy_fp="$(fp_of_file "$LEGACY_CERT")"
    EXPECTED_LABEL["$legacy_fp"]="retired F13 CA (GA_LEGACY_CA_BRIDGE=true)"
  else
    _bad "GA_LEGACY_CA_BRIDGE=true but ${LEGACY_CERT} is missing — the bake is inconsistent"
  fi
fi

# --- KEYRING-01: the in-tree legacy cert is the one we audited -------------
if [[ -f "$LEGACY_CERT" ]]; then
  actual_legacy_fp="$(fp_of_file "$LEGACY_CERT")"
  if [[ "$actual_legacy_fp" == "$LEGACY_FP_PINNED" ]]; then
    _ok "KEYRING-01: in-tree legacy cert matches the pinned fingerprint"
  else
    _bad "KEYRING-01: legacy-signing-cert.pem was SWAPPED — ${actual_legacy_fp} != pinned ${LEGACY_FP_PINNED}"
  fi
fi

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

# --- KEYRING-04: the legacy bridge matches the gate, in the ARTIFACT ------
# RAUC-LEGACY-01 proves the function honours the flag. This proves the image does.
if [[ -n "$legacy_fp" || -f "$LEGACY_CERT" ]]; then
  probe_fp="${legacy_fp:-$LEGACY_FP_PINNED}"
  legacy_in_image=false
  [[ -n "${SHIPPED_SUBJ[$probe_fp]:-}" ]] && legacy_in_image=true
  if [[ "$LEGACY_GATE" == "true" && "$legacy_in_image" == true ]]; then
    _ok "KEYRING-04: retired F13 CA present, as GA_LEGACY_CA_BRIDGE=true declares (expected while pre-rotation devices remain — Odoo #534)"
  elif [[ "$LEGACY_GATE" != "true" && "$legacy_in_image" == false ]]; then
    _ok "KEYRING-04: retired F13 CA absent, as GA_LEGACY_CA_BRIDGE=${LEGACY_GATE} declares"
  elif [[ "$LEGACY_GATE" != "true" && "$legacy_in_image" == true ]]; then
    _bad "KEYRING-04: retired F13 CA is IN the image although GA_LEGACY_CA_BRIDGE=${LEGACY_GATE} — the gate did not hold"
  else
    _bad "KEYRING-04: GA_LEGACY_CA_BRIDGE=true but the retired F13 CA is NOT in the image — the bake diverged from the declaration"
  fi
fi

# --- KEYRING-06: the clean cut must be defended, not merely declared -----
# KEYRING-04 above checks that the image MATCHES the declaration. It cannot
# check that the declaration is right: it derives the expected anchor set FROM
# GA_LEGACY_CA_BRIDGE, so flipping that flag back to "true" makes the retired
# CA "expected" and KEYRING-04 reports it as OK. The whole audit then stays
# green while every shipped device trusts the key the 2026-07-29 rotation
# retired — a one-line change to meta, with the cert already sitting next to it
# in the tree, and nothing that says no.
#
# The 2026-07-29 rotation was commissioned as a CLEAN CUT: exactly one anchor,
# no bridge, no dual trust. So on a production build the bridge being ON is a
# finding by itself, independent of what the image contains. Turning it back on
# for a genuine migration then requires deleting this check on purpose — which
# is the point. A trust decision should cost a deliberate act, not a flag.
if [[ "$GA_ENV" == "prod" || "$DEPLOYMENT" == "production" ]]; then
  if [[ "$LEGACY_GATE" == "true" ]]; then
    _bad "KEYRING-06: GA_LEGACY_CA_BRIDGE=true on a PRODUCTION build — the retired pre-2026-07-29 signing CA would be trusted fleet-wide. The rotation was a clean cut; if a bridge release is genuinely intended, remove this check in the same commit that explains why."
  else
    _ok "KEYRING-06: clean cut holds — GA_LEGACY_CA_BRIDGE=${LEGACY_GATE} on a production build"
  fi
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
