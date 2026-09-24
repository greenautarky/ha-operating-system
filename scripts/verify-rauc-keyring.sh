#!/usr/bin/env bash
# verify-rauc-keyring.sh — assert WHAT IS ACTUALLY IN the RAUC keyring of a build
#
# Usage:
#   ./scripts/verify-rauc-keyring.sh <output_dir>        # e.g. ga_output (has target/)
#   ./scripts/verify-rauc-keyring.sh --print <pem>       # dump fingerprints of a bundle
#   ./scripts/verify-rauc-keyring.sh --check-root <pem>  # is <pem> exactly the pinned root?
#
# Exit codes (distinct on purpose, same convention as scan-cves.sh):
#   0  the shipped keyring holds exactly the pinned OTA root, nothing else
#   1  findings: an extra / missing / wrong / expired trust anchor   (fatal)
#   2  the check itself could not run                                (fatal)
#
# WHY THIS EXISTS
#   /etc/rauc/keyring.pem is the ONLY thing standing between a device and an
#   attacker-signed OTA. install_rauc_certs() in buildroot-external/scripts/
#   rauc.sh writes it from ota/rel-ca.pem, and appends the signing certificate
#   whenever that certificate does not chain to the root. Nothing else may put a
#   certificate there, and nothing else asserts the RESULT: OTA-05 only checks
#   that the file exists.
#
#   One OTA root, one signing certificate under it (ADR-0027 Amendment 1, D9).
#   So the expected keyring is not "whatever the build inputs were" — it is ONE
#   certificate whose SHA-256 fingerprint is pinned below as a constant. An
#   audit must never derive its expectation from the artefact it audits (N7):
#   if rel-ca.pem on the builder is swapped, a derived expectation follows the
#   swap and stays green. The pin does not.
#
#   A wrong trust anchor is expensive to correct. The rootfs is a read-only
#   squashfs/erofs and /etc/rauc is NOT one of the paths bind-mounted from
#   /mnt/overlay (see usr/libexec/hassos-overlay), so it cannot be edited in
#   place; and `rauc install` verifies against the keyring the device already
#   runs, so the supported update path is exactly what a bad keyring blocks.
#   What remains is a manual raw write to the inactive slot over SSH, once per
#   device (see docs/RAUC-KEYRING.md). Build time is the only cheap moment.
#
# Related: Odoo #624 (this audit), OS#309 (retired-CA bridge removed),
#          ADR-0027 D9 (one key, one build mode).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# THE OTA root CA — SHA-256 fingerprint, pinned. The only certificate a GA OS
# keyring may contain. Changing this line is a root rotation: it needs a bridge
# release and a hardware proof first (docs/RAUC-KEYRING.md, "Rotating").
# tests/gates/rauc_keyring/selftest.sh extracts this exact assignment.
GA_OTA_ROOT_FP="C1:B7:57:33:1C:AE:F8:C1:36:40:81:C3:39:CE:34:80:FD:C6:9E:42:D0:ED:73:2F:CA:C0:AA:9F:0F:6A:83:17"

# Warn this many days before the root expires. The root outlives the signing
# certificate by years; this is the lead time a root rotation needs.
EXPIRY_WARN_DAYS="${EXPIRY_WARN_DAYS:-365}"

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' RESET='\033[0m'
[[ -t 1 ]] || { GREEN=''; RED=''; YELLOW=''; RESET=''; }
_ok()   { echo -e "  ${GREEN}OK${RESET}    $1"; }
_bad()  { echo -e "  ${RED}FAIL${RESET}  $1"; findings=$((findings+1)); }
_warn() { echo -e "  ${YELLOW}WARN${RESET}  $1"; warns=$((warns+1)); }

findings=0
warns=0

# A placeholder or a malformed pin would make every comparison below fail for
# the wrong reason — or, worse, match nothing and be "fixed" by editing the
# pin to whatever the build produced. Refuse to run instead.
if [[ ! "$GA_OTA_ROOT_FP" =~ ^([0-9A-F]{2}:){31}[0-9A-F]{2}$ ]]; then
  echo "ERROR: GA_OTA_ROOT_FP is not a SHA-256 fingerprint ('${GA_OTA_ROOT_FP}')." >&2
  echo "       The audit has nothing to compare against. Pin the real root." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# cert_records <pem-bundle> -> "<sha256-fp>\t<subject>\t<notAfter>\t<isCA>" per cert
#
# The bundle is NOT a clean PEM file: install_rauc_certs appends with
# `openssl x509 -text`, so human-readable blocks sit between the PEM armour.
# `openssl x509 -in <bundle>` would read only the FIRST certificate and report
# success — which is precisely how a smuggled-in trust anchor stays invisible.
# Split on the armour and fingerprint every block. A block that does not parse
# is emitted as "UNPARSEABLE" rather than dropped: dropping it would let a
# corrupted extra certificate vanish from the count.
# ---------------------------------------------------------------------------
cert_records() {
  local bundle="$1" dir cert subj fp end ca
  dir="$(mktemp -d)" || return 2
  awk -v d="$dir" '
    /-----BEGIN CERTIFICATE-----/ { n++; f = sprintf("%s/c%04d.pem", d, n); inc = 1 }
    inc { print > f }
    /-----END CERTIFICATE-----/   { inc = 0 }
  ' "$bundle"
  for cert in "$dir"/c*.pem; do
    [[ -e "$cert" ]] || continue
    fp="$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')"
    if [[ -z "$fp" ]]; then
      printf 'UNPARSEABLE\t%s\t-\t-\n' "$(basename "$cert")"
      continue
    fi
    subj="$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/^subject=*//')"
    end="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    if openssl x509 -in "$cert" -noout -text 2>/dev/null | grep -q 'CA:TRUE'; then ca=yes; else ca=no; fi
    printf '%s\t%s\t%s\t%s\n' "$fp" "$subj" "$end" "$ca"
  done
  rm -rf "$dir"
}

# --print mode: inspect any bundle (a build's keyring, or one pulled off a
# device with `scp <dev>:/etc/rauc/keyring.pem`).
if [[ "${1:-}" == "--print" ]]; then
  [[ -f "${2:-}" ]] || { echo "usage: $0 --print <keyring.pem>" >&2; exit 2; }
  command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl not found" >&2; exit 2; }
  cert_records "$2" | while IFS=$'\t' read -r fp subj end ca; do
    _pin=""; [[ "$fp" == "$GA_OTA_ROOT_FP" ]] && _pin="   <- pinned OTA root"
    printf '%s%s\n    subject: %s\n    expires: %s   CA: %s\n' "$fp" "$_pin" "$subj" "$end" "$ca"
  done
  exit 0
fi

# --check-root mode: ga_build.sh asks this BEFORE the build starts, so a wrong
# ota/rel-ca.pem fails in seconds rather than after the rootfs is built. Same
# pinned constant as the audit — there is exactly one definition of it.
if [[ "${1:-}" == "--check-root" ]]; then
  [[ -f "${2:-}" ]] || { echo "usage: $0 --check-root <rel-ca.pem>" >&2; exit 2; }
  command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl not found" >&2; exit 2; }
  mapfile -t _recs < <(cert_records "$2")
  if (( ${#_recs[@]} != 1 )); then
    echo "  FAIL  $2 holds ${#_recs[@]} certificate(s); the OTA root file must hold exactly one" >&2
    exit 1
  fi
  _fp="${_recs[0]%%$'\t'*}"
  if [[ "$_fp" != "$GA_OTA_ROOT_FP" ]]; then
    echo "  FAIL  $2 is not the pinned OTA root (got ${_fp})" >&2
    exit 1
  fi
  echo "  OK    $2 is the pinned OTA root"
  exit 0
fi

OUT="${1:?Usage: $0 <output_dir>   (or --print <keyring.pem> | --check-root <pem>)}"
# Accept either the build output dir (has target/) or the target dir itself.
TARGET="${OUT}/target"
[[ -d "$TARGET" ]] || TARGET="$OUT"
KEYRING="${TARGET}/etc/rauc/keyring.pem"
OTA_DIR="${REPO_ROOT}/buildroot-external/ota"
META="${REPO_ROOT}/buildroot-external/meta"
BR_SCRIPTS="${REPO_ROOT}/buildroot-external/scripts"

echo ""
echo "=== RAUC keyring audit ==="
echo "  Keyring:     $KEYRING"
echo "  Pinned root: ${GA_OTA_ROOT_FP:0:23}...   (one key, one build mode — ADR-0027 D9)"

command -v openssl >/dev/null 2>&1 \
  || { echo "  ERROR: openssl not found — cannot verify the keyring" >&2; exit 2; }
[[ -f "$META" ]] \
  || { echo "  ERROR: no buildroot-external/meta under ${REPO_ROOT}" >&2; exit 2; }
[[ -f "${BR_SCRIPTS}/rauc.sh" ]] \
  || { echo "  ERROR: no buildroot-external/scripts/rauc.sh under ${REPO_ROOT} — cannot check KEYRING-06" >&2; exit 2; }
if [[ ! -f "$KEYRING" ]]; then
  echo "  ERROR: no keyring at ${KEYRING} — build output missing or rauc.sh did not run" >&2
  exit 2
fi

# --- the shipped set ------------------------------------------------------
blocks=0
unparseable=0
declare -A SHIPPED_SUBJ=() SHIPPED_END=() SHIPPED_CA=()
while IFS=$'\t' read -r fp subj end ca; do
  [[ -n "$fp" ]] || continue
  blocks=$((blocks+1))
  if [[ "$fp" == "UNPARSEABLE" ]]; then unparseable=$((unparseable+1)); continue; fi
  SHIPPED_SUBJ["$fp"]="$subj"
  SHIPPED_END["$fp"]="$end"
  SHIPPED_CA["$fp"]="$ca"
done < <(cert_records "$KEYRING")

if (( blocks == 0 )); then
  echo "  ERROR: no certificate parsed out of ${KEYRING} — keyring is empty or malformed" >&2
  exit 2
fi

echo "  Trust anchors in the shipped keyring: ${#SHIPPED_SUBJ[@]} distinct (${blocks} blocks)"
for fp in "${!SHIPPED_SUBJ[@]}"; do
  printf '    %s\n      %s   (expires %s, CA: %s)\n' "$fp" "${SHIPPED_SUBJ[$fp]}" "${SHIPPED_END[$fp]}" "${SHIPPED_CA[$fp]}"
done
echo ""

# --- KEYRING-02: nothing but the pinned root ------------------------------
# Stricter since D9: the expectation is the pinned constant, not the build's
# declared inputs, and there is no longer a tolerated "locally generated dev
# signing cert" — every extra certificate is a finding. The keyring must be
# exactly ONE block: a duplicate of the root is harmless on a device but means
# the assembly appended something it should not have, which is the bug class
# this audit exists for.
extra=0
for fp in "${!SHIPPED_SUBJ[@]}"; do
  [[ "$fp" == "$GA_OTA_ROOT_FP" ]] && continue
  extra=$((extra+1))
  _bad "KEYRING-02: trust anchor that is NOT the pinned OTA root: ${fp} — '${SHIPPED_SUBJ[$fp]}'"
done
if (( unparseable > 0 )); then
  _bad "KEYRING-02: ${unparseable} certificate block(s) in the keyring do not parse — something unverifiable is in the trust set"
fi
if (( blocks != 1 )); then
  _bad "KEYRING-02: the keyring holds ${blocks} certificate blocks; exactly 1 (the OTA root) is allowed"
fi
(( extra == 0 && unparseable == 0 && blocks == 1 )) \
  && _ok "KEYRING-02: the keyring holds exactly one certificate block and no other anchor"

# --- KEYRING-03: the pinned root is there, and it is a CA -----------------
# Stricter since D9: presence of the PINNED root, not of whatever the build
# declared; and it must carry CA:TRUE, because a root that cannot issue cannot
# chain the signing certificate — every bundle would then be rejected, or,
# worse, the signing cert would get appended as a second anchor.
if [[ -z "${SHIPPED_SUBJ[$GA_OTA_ROOT_FP]:-}" ]]; then
  _bad "KEYRING-03: the pinned OTA root (${GA_OTA_ROOT_FP:0:23}...) is NOT in the shipped keyring — this image trusts something else"
elif [[ "${SHIPPED_CA[$GA_OTA_ROOT_FP]}" != "yes" ]]; then
  _bad "KEYRING-03: the pinned OTA root is present but not marked CA:TRUE — it cannot chain the signing certificate"
else
  _ok "KEYRING-03: the pinned OTA root is present and is a CA"
fi

# --- KEYRING-06: retired signing paths are GONE, not merely off -----------
# Two retired paths, both asserted ABSENT from the tree:
#
#   * the pre-2026-03-27 CA bridge (OS#309, 2026-07-30 hard cut): a
#     non-revocable CA:TRUE root valid to 2035. The flag, the cert and the bake
#     function were deleted; re-introducing it needs all three.
#   * the dev key (ADR-0027 D9): a second signing pair selected by a build-mode
#     variable, and a fallback that read signing keys from the source checkout.
#     Stricter since D9: the selector and the fallback must not exist in the
#     keyring/signing code at all, because a switch left next to its material is
#     one line from being flipped.
#
# Bridge-FORWARD is unaffected: signing a new image with an OLD key never needed
# the old certificate in anybody's keyring.
_residue=""
[[ -f "${OTA_DIR}/legacy-signing-cert.pem" ]] && _residue+="ota/legacy-signing-cert.pem "
grep -q '^GA_LEGACY_CA_BRIDGE=' "$META" 2>/dev/null && _residue+="GA_LEGACY_CA_BRIDGE-in-meta "
grep -rq 'function add_legacy_ca_if_enabled' "$BR_SCRIPTS" 2>/dev/null && _residue+="add_legacy_ca_if_enabled() "
# Code only — comments may explain the history. The patterns are the shapes
# the dev path had: its selector, its CA file, its key names, and the checkout
# fallback for signing material.
_sign_code="$(grep -hv '^[[:space:]]*#' "${BR_SCRIPTS}/rauc.sh" "${BR_SCRIPTS}/hdd-image.sh" 2>/dev/null)"
for _pat in 'ga_is_prod' 'GA_ENV' 'dev-ca' 'dev-signing' 'dev-cert\.pem' 'dev-key\.pem' '/build/key\.pem' '/build/cert\.pem' 'generate-signing-key'; do
  printf '%s\n' "$_sign_code" | grep -qE -- "$_pat" && _residue+="signing-code:'${_pat//\\/}' "
done
if [[ -z "$_residue" ]]; then
  _ok "KEYRING-06: retired signing paths fully removed (no CA bridge, no dev key selector, no checkout fallback)"
else
  _bad "KEYRING-06: retired signing-path RESIDUE present: ${_residue}— a one-line change could sign or trust with material the fleet must not accept"
fi

# --- KEYRING-05: an expired anchor bricks OTA for the whole fleet ---------
# Stricter since D9: an expiry date that cannot be read is a finding. It used to
# be skipped (`|| continue`), which made "cannot tell" look like "fine".
now_s=$(date +%s)
for fp in "${!SHIPPED_END[@]}"; do
  if ! end_s=$(date -d "${SHIPPED_END[$fp]}" +%s 2>/dev/null); then
    _bad "KEYRING-05: expiry of ${fp} could not be read ('${SHIPPED_END[$fp]}') — validity UNVERIFIED"
    continue
  fi
  days=$(( (end_s - now_s) / 86400 ))
  if (( days < 0 )); then
    _bad "KEYRING-05: trust anchor EXPIRED ${days#-} days ago: ${fp} — OTA verification will fail"
  elif (( days < EXPIRY_WARN_DAYS )); then
    _warn "KEYRING-05: trust anchor expires in ${days} days: ${fp} — plan the rotation (it needs a bridge release)"
  else
    _ok "KEYRING-05: ${fp:0:23}... valid for another ${days} days"
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
