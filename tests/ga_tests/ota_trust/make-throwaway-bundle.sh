#!/usr/bin/env bash
# make-throwaway-bundle.sh — build a tiny RAUC bundle signed with a key that
# exists for one minute, for the KEYRING-NEG device test (ADR-0027 D9).
#
# Usage:
#   tests/ga_tests/ota_trust/make-throwaway-bundle.sh <outdir>
#
# Produces:
#   <outdir>/throwaway.raucb      verity bundle, compatible=haos-ihost
#   <outdir>/throwaway-cert.pem   the throwaway certificate (public)
#
# The PRIVATE key is generated in a temp dir and deleted before this script
# exits: nobody, including whoever ran this, can sign anything with it again.
# That is the point — a bundle whose signer is trusted by nothing.
#
# Host requirements: `rauc` and `mksquashfs` on PATH. Without them the script
# re-runs itself in a throwaway Debian container (docker) that has both; set
# GA_TRUST_NO_DOCKER=1 to forbid that and fail instead.
#
# Built to be harmless if a device wrongly ACCEPTS it:
#   * the only image targets slot class `ga-trust-probe`, which no GA system.conf
#     defines, so an install that got past the signature still has nowhere to
#     write;
#   * no hooks;
#   * the payload is 64 KiB of random bytes.
set -euo pipefail

OUT="${1:?usage: $0 <outdir>}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
COMPATIBLE="${GA_TRUST_COMPATIBLE:-haos-ihost}"

if ! command -v rauc >/dev/null 2>&1 || ! command -v mksquashfs >/dev/null 2>&1; then
  if [[ "${GA_TRUST_NO_DOCKER:-0}" == "1" ]] || ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: need rauc + mksquashfs on PATH (or docker to borrow them)." >&2
    exit 2
  fi
  echo "rauc/mksquashfs not on this host — building inside a throwaway debian container"
  exec docker run --rm \
    -e GA_TRUST_NO_DOCKER=1 -e GA_TRUST_COMPATIBLE="$COMPATIBLE" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$SELF":/work/make.sh:ro -v "$OUT":/out \
    debian:trixie-slim bash -c '
      set -e
      apt-get update -qq >/dev/null
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rauc squashfs-tools openssl >/dev/null
      bash /work/make.sh /out
      chown -R "$HOST_UID:$HOST_GID" /out'
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/content"

# 1) the throwaway signer — self-signed, one day, never stored
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj "/O=GA throwaway/CN=GA throwaway OTA signer (KEYRING-NEG, must be rejected)" \
  -keyout "$T/key.pem" -out "$T/cert.pem" >/dev/null 2>&1

# 2) a minimal, well-formed bundle
# random, not zeros: squashfs compresses zeros below the 4 KiB minimum rauc accepts
dd if=/dev/urandom of="$T/content/probe.img" bs=1024 count=64 status=none
cat > "$T/content/manifest.raucm" <<EOF
[update]
compatible=${COMPATIBLE}
version=0.0.0-keyring-neg

[bundle]
format=verity

[image.ga-trust-probe]
filename=probe.img
EOF

rm -f "$OUT/throwaway.raucb"
rauc bundle --cert="$T/cert.pem" --key="$T/key.pem" "$T/content" "$OUT/throwaway.raucb" >/dev/null
cp "$T/cert.pem" "$OUT/throwaway-cert.pem"

# 3) prove it here, before anyone carries it to a device: it verifies against
#    its own cert (well-formed) — the device test repeats this as KEYRING-NEG-01.
rauc info --keyring="$OUT/throwaway-cert.pem" "$OUT/throwaway.raucb" >/dev/null

# 4) and the key is gone (the trap removes $T; say so explicitly)
rm -f "$T/key.pem"
echo "OK: $OUT/throwaway.raucb ($(wc -c < "$OUT/throwaway.raucb") bytes), signer:"
openssl x509 -in "$OUT/throwaway-cert.pem" -noout -subject -fingerprint -sha256 | sed 's/^/    /'
echo "The private key has been deleted. Copy both files to the device and run"
echo "  THROWAWAY_RAUCB=... THROWAWAY_CERT=... sh ga_tests/ota_trust/test.sh"
