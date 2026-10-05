#!/usr/bin/env bash
# =============================================================================
# ga-issue-device-certs.sh — issue short-lived SSH certificates for SEVERAL
# devices in one run, signed by the CA on an inserted YubiKey.
# =============================================================================
# A thin batch wrapper around ga-sign-ssh-cert.sh (ADR-0019 step 2). Every
# rule that makes a certificate scoped and auditable stays in that script:
# principals validated, validity capped at 24 h, key id, serial, local ledger,
# optional fleet-manager mirror. This file only adds the loop and the file
# naming, so an operator does not have to hand-copy key files per device.
#
# Usage:
#   ga-issue-device-certs.sh [--token a|b] [--hours N] [--key <user-key>] [--one-cert] DEVICE...
#
#   DEVICE   K31 / 31 / KIB-SON-00000031  (any of these forms)
#   --token  which CA token is inserted: a (default) or b
#   --hours  certificate lifetime, 1..24 (default 8)
#   --key    the operator key pair to certify (default ~/.ssh/ga-operator-ed25519)
#   --one-cert  ONE certificate naming all devices (max 5): one PIN + one
#            touch instead of one per device. Every device must carry the
#            fleet-manager tag `canary`, or nothing is signed.
#
# Each certificate names the device's label AND its hardware anchor
# (hw_serial), read from the fleet-manager. A device that only knows its
# anchor (label file missing, fresh device) refuses a label-only certificate,
# so a missing anchor is an error here, never a silent narrowing.
#
# Output per device: <key>-k<NN>-cert.pub next to the key, e.g.
#   ~/.ssh/ga-operator-ed25519-k31-cert.pub
# which an ssh_config entry uses as CertificateFile (alongside IdentityFile
# <key>). The YubiKey asks for its PIN once per device, because each
# certificate is a separate signing operation on the token.
#
# Environment (all optional):
#   GA_CEREMONY_DIR   folder holding ca_a.pub / ca_b.pub
#                     (default ~/ga-ssh-ceremony-2026-09-29)
#   GA_SSH_PKCS11     PKCS#11 module (default: libykcs11.so found on the system)
#   GA_CERT_KEYID     key id written into each cert (default: $USER@ga)
#   GA_FLEET_URL      fleet-manager base URL (required unless GA_FLEET_VIA is set)
#   GA_FLEET_TOKEN    bearer token (default: ~/.config/ga/fleet-manager.token)
#   GA_FLEET_VIA      ssh host to ask the fleet-manager FROM, when this machine
#                     has no mesh route (e.g. ga-newhost; then GA_FLEET_URL is
#                     taken as seen from that host, default http://127.0.0.1:8090)
# -----------------------------------------------------------------------------
set -euo pipefail

die() { echo "ga-issue-device-certs: $*" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIGNER="$HERE/ga-sign-ssh-cert.sh"
[[ -x "$SIGNER" ]] || die "missing $SIGNER"

TOKEN=a; HOURS=8; KEY="$HOME/.ssh/ga-operator-ed25519"; ONE=0
devices=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) TOKEN="${2:-}"; shift 2 ;;
    --hours) HOURS="${2:-}"; shift 2 ;;
    --key)   KEY="${2:-}"; shift 2 ;;
    --one-cert) ONE=1; shift ;;
    -h|--help) sed -n '2,48p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) devices+=("$1"); shift ;;
  esac
done
(( ${#devices[@]} > 0 )) || die "name at least one device, e.g.: $(basename "$0") K31 K7 K55"
[[ "$TOKEN" == a || "$TOKEN" == b ]] || die "--token must be a or b"
if ! [[ "$HOURS" =~ ^[0-9]+$ ]] || (( HOURS < 1 || HOURS > 24 )); then die "--hours must be 1..24"; fi
[[ -r "$KEY.pub" ]] || die "cannot read $KEY.pub"

# Self-test only: a file-backed CA (GA_SSH_CA_KEY + GA_SSH_ALLOW_FILE_CA=1) is
# passed straight to the signer, which refuses it outside that switch.
TEST_CA=0
if [[ -n "${GA_SSH_CA_KEY:-}" ]]; then
  [[ "${GA_SSH_ALLOW_FILE_CA:-}" == 1 ]] || die "GA_SSH_CA_KEY is for the self-test only (needs GA_SSH_ALLOW_FILE_CA=1)"
  TEST_CA=1
fi
CEREMONY="${GA_CEREMONY_DIR:-$HOME/ga-ssh-ceremony-2026-09-29}"
CA_PUB="$CEREMONY/ca_${TOKEN}.pub"
if (( ! TEST_CA )); then
[[ -r "$CA_PUB" ]] || die "cannot read $CA_PUB (set GA_CEREMONY_DIR)"
if [[ -z "${GA_SSH_PKCS11:-}" ]]; then
  for c in /usr/lib/x86_64-linux-gnu/libykcs11.so /usr/lib/aarch64-linux-gnu/libykcs11.so \
           /usr/local/lib/libykcs11.so /usr/lib/libykcs11.so /opt/homebrew/lib/libykcs11.dylib; do
    [[ -r "$c" ]] && { GA_SSH_PKCS11="$c"; break; }
  done
fi
[[ -n "${GA_SSH_PKCS11:-}" && -r "$GA_SSH_PKCS11" ]] || die "no PKCS#11 module found — install yubico-piv-tool or set GA_SSH_PKCS11"
fi

# Normalise K31 / 31 / KIB-SON-00000031 → KIB-SON-00000031, and validate.
labels=()
for d in "${devices[@]}"; do
  n="${d#KIB-SON-}"; n="${n#[Kk]}"
  [[ "$n" =~ ^[0-9]{1,8}$ ]] || die "cannot read '$d' as a device (use K31, 31 or KIB-SON-00000031)"
  labels+=("$(printf 'KIB-SON-%08d' "$((10#$n))")")
done

# --- fleet-manager lookups: anchor + tags per device ------------------------
FM_TOKEN="${GA_FLEET_TOKEN:-$(cat "$HOME/.config/ga/fleet-manager.token" 2>/dev/null || true)}"
[[ -n "$FM_TOKEN" ]] || die "no fleet-manager token (GA_FLEET_TOKEN or ~/.config/ga/fleet-manager.token)"
if [[ -n "${GA_FLEET_VIA:-}" ]]; then
  FM_URL="${GA_FLEET_URL:-http://127.0.0.1:8090}"
  fm_get() { ssh -o BatchMode=yes "$GA_FLEET_VIA" "curl -fsS --max-time 10 -H 'Authorization: Bearer $FM_TOKEN' '${FM_URL%/}$1'"; }
else
  FM_URL="${GA_FLEET_URL:?set GA_FLEET_URL to the fleet-manager base URL, or GA_FLEET_VIA=<host> to ask it from that host}"
  fm_get() { curl -fsS --max-time 10 -H "Authorization: Bearer $FM_TOKEN" "${FM_URL%/}$1"; }
fi
declare -A ANCHOR
for label in "${labels[@]}"; do
  a=$(fm_get "/api/devices/$label/ssh-principals" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hw_serial") or "")') \
    || die "cannot ask the fleet-manager for $label (no mesh route? try GA_FLEET_VIA=ga-newhost)"
  [[ -n "$a" ]] || die "the fleet-manager has no hw_serial for $label — a label-only certificate may be refused by the device"
  ANCHOR[$label]="$a"
  if (( ONE )); then
    tags=$(fm_get "/api/devices/$label/tags" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin).get("tags") or []))') \
      || die "cannot read tags for $label"
    [[ " $tags " == *" canary "* ]] || die "--one-cert: $label is not tagged canary (tags: ${tags:-none}) — sign it on its own"
  fi
done
(( ! ONE || ${#labels[@]} <= 5 )) || die "--one-cert: at most 5 devices"

echo "CA token $TOKEN ($CA_PUB), lifetime ${HOURS}h, key $KEY.pub"
echo "devices: ${labels[*]}"
if (( ONE )); then echo "One certificate for all of them: one PIN + one touch."; else echo "The YubiKey asks for its PIN once per device."; fi
echo

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0

if (( ONE )); then
  first="${labels[0]}"; also=()
  for l in "${labels[@]:1}"; do also+=(--also "$l=${ANCHOR[$l]}"); done
  short="multi-$(for l in "${labels[@]}"; do printf 'k%d' "$((10#${l#KIB-SON-}))"; done)"
  tmp_pub="$work/$(basename "$KEY")-$short.pub"; cp "$KEY.pub" "$tmp_pub"
  if (( TEST_CA )); then
    sign=(env -u GA_SSH_PKCS11 GA_CERT_VALIDITY="+${HOURS}h" "$SIGNER" --anchor "${ANCHOR[$first]}" "${also[@]}" "$first" "$tmp_pub")
  else
    sign=(env GA_SSH_CA_PUB="$CA_PUB" GA_SSH_PKCS11="$GA_SSH_PKCS11" GA_CERT_VALIDITY="+${HOURS}h" "$SIGNER" --anchor "${ANCHOR[$first]}" "${also[@]}" "$first" "$tmp_pub")
  fi
  "${sign[@]}" || die "signing failed"
  multi="$KEY-$short-cert.pub"
  install -m 0644 "${tmp_pub%.pub}-cert.pub" "$multi"
  # Same file under every device's usual name, so existing ssh aliases work.
  for l in "${labels[@]}"; do install -m 0644 "$multi" "$KEY-k$((10#${l#KIB-SON-}))-cert.pub"; done
  echo "   -> $multi (also copied to each <key>-k<NN>-cert.pub)"
  ssh-keygen -L -f "$multi" | sed -n '/Principals:/,/Critical/p' | sed '1d;$d' | xargs echo "      principals:"
  ssh-keygen -L -f "$multi" | sed -n 's/^ *Valid: /      valid:      /p'
  exit 0
fi
for label in "${labels[@]}"; do
  short="k$((10#${label#KIB-SON-}))"
  tmp_pub="$work/$(basename "$KEY")-$short.pub"
  cp "$KEY.pub" "$tmp_pub"
  echo "== $label"
  if (( TEST_CA )); then
    sign=(env -u GA_SSH_PKCS11 GA_CERT_VALIDITY="+${HOURS}h" "$SIGNER" --anchor "${ANCHOR[$label]}" "$label" "$tmp_pub")
  else
    sign=(env GA_SSH_CA_PUB="$CA_PUB" GA_SSH_PKCS11="$GA_SSH_PKCS11" GA_CERT_VALIDITY="+${HOURS}h" "$SIGNER" --anchor "${ANCHOR[$label]}" "$label" "$tmp_pub")
  fi
  if "${sign[@]}"; then
    out="$KEY-$short-cert.pub"
    install -m 0644 "${tmp_pub%.pub}-cert.pub" "$out"
    valid=$(ssh-keygen -L -f "$out" | sed -n 's/^ *Valid: //p')
    princ=$(ssh-keygen -L -f "$out" | sed -n '/Principals:/,/Critical/p' | sed '1d;$d' | xargs)
    echo "   -> $out"
    echo "      principals: $princ"
    echo "      valid:      $valid"
  else
    echo "   FAILED for $label" >&2; fail=1
  fi
  echo
done

(( fail == 0 )) || die "at least one certificate was not issued — see above"
echo "Done. Use with: ssh -o IdentitiesOnly=yes -i $KEY -o CertificateFile=$KEY-k<NN>-cert.pub -p 22222 root@<device>"
