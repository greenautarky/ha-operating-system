#!/usr/bin/env bash
# =============================================================================
# ga-sign-ssh-cert.sh — issue a short-lived SSH certificate for ONE device.
# =============================================================================
# ADR-0019 step 2. Wraps `ssh-keygen -s` so the fields that make an access
# scoped and auditable are never left to memory:
#
#   -n  principals  which device this opens, and only that device: its
#                   hardware anchor and/or its fleet label (KIB-SON-XXXXXXXX)
#   -I  key id      WHO it was issued to. sshd logs it on every login at
#                   LogLevel VERBOSE, so the device's own log names the person.
#   -z  serial      a stable handle for one issuance (device log <-> ledger)
#   -V  validity    short by default (+8h); nothing here issues a long cert
#
# The CA private key never leaves its hardware token. Two ways to point at it:
#
#   GA_SSH_CA_PUB=<ca.pub>  GA_SSH_PKCS11=<libykcs11.so>   YubiKey PIV (normal)
#   GA_SSH_CA_KEY=<private key file>                       TEST CAs ONLY
#
# A file-backed CA is refused unless GA_SSH_ALLOW_FILE_CA=1 — that switch
# exists for the dry run and the self-test, never for a real issuance.
#
# Usage:
#   ga-sign-ssh-cert.sh [--anchor <hw_serial>] [--no-label] <KIB-SON-XXXXXXXX> <user-key.pub>
#
# Principals: the label is always the device id given. The anchor comes from
# --anchor, or — when GA_FLEET_URL + GA_FLEET_TOKEN are set — from the
# fleet-manager (GET /api/devices/<id>/ssh-principals), which is the only
# thing that holds the hw_serial <-> label mapping. With neither, the cert
# names the label only (it works once the device has its label).
# --no-label signs for the anchor alone (a fresh device before identity).
# -----------------------------------------------------------------------------
set -euo pipefail

VALIDITY="${GA_CERT_VALIDITY:-+8h}"
LEDGER="${GA_CERT_LEDGER:-$HOME/.local/state/ga/ssh-certs.log}"
SERIAL_STATE="${GA_CERT_SERIAL_STATE:-$HOME/.local/state/ga/ssh-cert-serial}"

die() { echo "ga-sign-ssh-cert: $*" >&2; exit 1; }

ANCHOR=""; USE_LABEL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --anchor)   ANCHOR="${2:-}"; shift 2 ;;
    --no-label) USE_LABEL=0; shift ;;
    --) shift; break ;;
    -*) die "unknown option $1" ;;
    *) break ;;
  esac
done
[[ $# -eq 2 ]] || die "usage: $(basename "$0") [--anchor <hw_serial>] [--no-label] <KIB-SON-XXXXXXXX> <user-key.pub>"
LABEL="$1"; PUBKEY="$2"

# The principals are the entire scoping mechanism: validated, never trusted.
# `kibu` is the name EVERY device ships with; a wildcard opens everything.
[[ "$LABEL" =~ ^KIB-SON-[0-9]{8}$ ]] \
  || die "refusing device '$LABEL' — must match ^KIB-SON-[0-9]{8}$ (never 'kibu', never a wildcard)"

if [[ -z "$ANCHOR" && -n "${GA_FLEET_URL:-}" && -n "${GA_FLEET_TOKEN:-}" ]]; then
  ANCHOR=$(curl -fsS --max-time 10 -H "Authorization: Bearer ${GA_FLEET_TOKEN}" \
             "${GA_FLEET_URL%/}/api/devices/${LABEL}/ssh-principals" \
           | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hw_serial") or "")') \
    || die "could not ask the fleet-manager for ${LABEL}'s anchor — pass --anchor or fix GA_FLEET_URL/GA_FLEET_TOKEN"
fi
if [[ -n "$ANCHOR" ]]; then
  [[ "$ANCHOR" =~ ^[A-Za-z0-9._-]+$ ]] || die "refusing anchor '$ANCHOR' — outside [A-Za-z0-9._-]"
  [[ "$ANCHOR" != "kibu" ]] || die "refusing anchor 'kibu' — the name every device ships with"
fi

principals=()
(( USE_LABEL )) && principals+=("$LABEL")
[[ -n "$ANCHOR" ]] && principals+=("$ANCHOR")
(( ${#principals[@]} > 0 )) || die "no principal left to sign for (--no-label without an anchor)"
PRINCIPALS_CSV="$(IFS=,; echo "${principals[*]}")"

[[ -r "$PUBKEY" ]] || die "cannot read public key: $PUBKEY"
grep -q -- '-cert-v01@openssh.com' "$PUBKEY" && die "$PUBKEY is already a certificate"
ssh-keygen -l -f "$PUBKEY" >/dev/null 2>&1 || die "$PUBKEY is not a public key"

# Validity: refuse anything that is not a short relative window.
[[ "$VALIDITY" =~ ^\+([0-9]+)([mhd])$ ]] || die "GA_CERT_VALIDITY must look like +8h / +30m / +1d"
case "${BASH_REMATCH[2]}" in
  m) (( BASH_REMATCH[1] <= 1440 )) ;; h) (( BASH_REMATCH[1] <= 24 )) ;; d) (( BASH_REMATCH[1] <= 1 )) ;;
esac || die "refusing validity $VALIDITY — at most 24 h"

if [[ -n "${GA_SSH_PKCS11:-}" ]]; then
  [[ -r "${GA_SSH_CA_PUB:-}" ]] || die "GA_SSH_PKCS11 set: GA_SSH_CA_PUB must name the CA public key of the inserted token"
  ca_args=(-s "$GA_SSH_CA_PUB" -D "$GA_SSH_PKCS11")
elif [[ -n "${GA_SSH_CA_KEY:-}" ]]; then
  [[ "${GA_SSH_ALLOW_FILE_CA:-0}" == "1" ]] \
    || die "a file-backed CA key is for test CAs only; set GA_SSH_ALLOW_FILE_CA=1 if this IS a test"
  ca_args=(-s "$GA_SSH_CA_KEY")
else
  die "no CA: set GA_SSH_CA_PUB + GA_SSH_PKCS11 (YubiKey PIV)"
fi

# Serial: monotonic, never reused (epoch seconds, bumped on collision).
mkdir -p "$(dirname "$SERIAL_STATE")" "$(dirname "$LEDGER")"
now=$(date -u +%s)
last=$(cat "$SERIAL_STATE" 2>/dev/null || echo 0)
serial=$(( now > last ? now : last + 1 ))

WHO="${GA_CERT_IDENTITY:-${USER:-unknown}}"
[[ "$WHO" =~ ^[A-Za-z0-9._@-]+$ ]] || die "refusing key id '$WHO'"
KEYID="${WHO}@ga"
OUT="${PUBKEY%.pub}-cert.pub"

# -O clear -O permit-pty: grant only a shell. ssh-keygen's defaults grant X11,
# agent and port forwarding; sshd refuses them anyway, but the certificate is
# the document an auditor reads and must not claim more than it carries.
ssh-keygen "${ca_args[@]}" -I "$KEYID" -n "$PRINCIPALS_CSV" -V "$VALIDITY" -z "$serial" \
  -O clear -O permit-pty "$PUBKEY"
printf '%s' "$serial" > "$SERIAL_STATE"

printf '%s\tserial=%s\tid=%s\tprincipals=%s\tvalidity=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$serial" "$KEYID" "$PRINCIPALS_CSV" "$VALIDITY" >> "$LEDGER"

# Mirror the issuance to the fleet-manager ledger when configured. The LOCAL
# ledger above is written first and unconditionally; a failed mirror is loud
# but does not undo a certificate that is already signed.
if [[ -n "${GA_FLEET_URL:-}" && -n "${GA_FLEET_TOKEN:-}" ]]; then
  ca_fp=$(ssh-keygen -L -f "$OUT" | awk '/Signing CA/{print $4}')
  from_t=$(ssh-keygen -L -f "$OUT" | awk '/Valid:/{print $3}')
  to_t=$(ssh-keygen -L -f "$OUT" | awk '/Valid:/{print $5}')
  if curl -fsS --max-time 10 -X POST "${GA_FLEET_URL%/}/api/ssh-certificates" \
       -H "Authorization: Bearer ${GA_FLEET_TOKEN}" -H 'Content-Type: application/json' \
       -d "$(printf '{"serial":"%s","key_id":"%s","principal":"%s","valid_from":"%s","valid_to":"%s","ca_fingerprint":"%s"}' \
             "$serial" "$KEYID" "$LABEL" "$from_t" "$to_t" "$ca_fp")" >/dev/null; then
    echo "  ledger: mirrored to fleet-manager"
  else
    echo "  WARNING: could not mirror this issuance to the fleet-manager. The certificate IS valid and IS in $LEDGER — re-send the central copy." >&2
  fi
fi

echo "issued: $OUT"
# -A1 on Principals is load-bearing: ssh-keygen prints them on the NEXT lines.
ssh-keygen -L -f "$OUT" | grep -E -A2 'Key ID|Serial|Valid:|Principals' | grep -vE '^--$' | sed 's/^\s*/  /'
echo "ledger: $LEDGER"
