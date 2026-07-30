#!/usr/bin/env bash
# gen-ota-ca.sh — mint a 2-tier OTA signing hierarchy for GA OS.
#
# Usage (run ON ga-builder, as root):
#   scp scripts/ops/gen-ota-ca.sh ga-builder:/tmp/
#   ssh ga-builder 'bash /tmp/gen-ota-ca.sh'
#
# Env overrides:
#   STAGE=/root/ga-ota-ca-<date>   output dir (refuses to overwrite)
#   ORG / ROOT_CN / SIGN_CN        subjects
#   ROOT_DAYS=5478 SIGN_DAYS=1095  validity (15 y / 3 y)
#
# WHY TWO TIERS — this is the whole point, do not "simplify" it back to one.
# Until 2026-07-29 the trust anchor WAS the signing certificate: /build/cert.pem
# was a self-signed cert (from generate-signing-key.sh), buildroot-external/ota/
# rel-ca.pem was a *different* self-signed CA that signed nothing, and because
# cert.pem did not verify against it, install_rauc_certs() appended cert.pem to
# every device's keyring. Consequence: rotating the signing key meant rotating
# the fleet's trust anchor, i.e. a full bridge-forward migration of every
# device. That is why the 2026-03-27 rotation needed GA_LEGACY_CA_BRIDGE.
#
# With a root CA in the keyring and a separate signing cert issued by it,
# rotating the signing key is a build-server change and the fleet never
# notices. The root key is then only needed to issue the next signing cert —
# keep it OFFLINE, not on the builder.
#
# DELIBERATELY OMITTED:
#   - extendedKeyUsage=codeSigning. RAUC verifies via OpenSSL CMS and the
#     certs proven to work in this fleet carry no EKU. Adding one is a purpose-
#     check risk with no verified upside; if you want it, prove it on a device
#     first (a rejected bundle here means every device stops updating).
#   - CRL distribution points. There is no CRL infrastructure, and system.conf
#     sets no check-crl — advertising a CRL nobody publishes is worse than none.
#     Revocation is "ship an image without the cert", which is why SIGN_DAYS is
#     short and the root is pathlen:0.
#
# See docs/RAUC-KEYRING.md for how to install the result and the bridge-forward
# order it has to be rolled out in. [Odoo #628]
set -euo pipefail

STAGE="${STAGE:-/root/ga-ota-ca-$(date +%Y%m%d)}"
ORG="${ORG:-GreenAutarky GmbH}"
ROOT_CN="${ROOT_CN:-GreenAutarky OTA Root CA 2026}"
SIGN_CN="${SIGN_CN:-GreenAutarky OTA Signing 2026-07}"
ROOT_DAYS="${ROOT_DAYS:-5478}"
SIGN_DAYS="${SIGN_DAYS:-1095}"

umask 077
mkdir -p "$STAGE"
cd "$STAGE"

# Never clobber key material: a silently overwritten root key is an
# unrecoverable fleet event, not a rerun.
if [[ -e ga-ota-root-ca.key ]]; then
  echo "REFUSING: ${STAGE}/ga-ota-root-ca.key exists — pick another STAGE." >&2
  exit 1
fi

cat > openssl-root.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3_ca
prompt             = no
[dn]
O  = ${ORG}
CN = ${ROOT_CN}
[v3_ca]
basicConstraints       = critical,CA:TRUE,pathlen:0
keyUsage               = critical,keyCertSign,cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always
EOF

cat > openssl-signing.cnf <<EOF
[req]
distinguished_name = dn
prompt             = no
[dn]
O  = ${ORG}
CN = ${SIGN_CN}
[v3_leaf]
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
EOF

echo "==> root CA key (RSA-4096)"
openssl genrsa -out ga-ota-root-ca.key 4096 2>/dev/null

echo "==> root CA cert (self-signed, ${ROOT_DAYS} days)"
openssl req -new -x509 -key ga-ota-root-ca.key -out ga-ota-root-ca.pem \
  -days "$ROOT_DAYS" -sha256 -config openssl-root.cnf -extensions v3_ca \
  -set_serial "0x$(openssl rand -hex 16)"

echo "==> signing key (RSA-4096)"
openssl genrsa -out ga-ota-signing.key 4096 2>/dev/null

echo "==> signing cert, issued by the root (${SIGN_DAYS} days)"
openssl req -new -key ga-ota-signing.key -out ga-ota-signing.csr -config openssl-signing.cnf
openssl x509 -req -in ga-ota-signing.csr -CA ga-ota-root-ca.pem -CAkey ga-ota-root-ca.key \
  -out ga-ota-signing.pem -days "$SIGN_DAYS" -sha256 \
  -extfile openssl-signing.cnf -extensions v3_leaf \
  -set_serial "0x$(openssl rand -hex 16)" 2>/dev/null

chmod 600 ./*.key
chmod 644 ./*.pem
rm -f ga-ota-signing.csr

echo
echo "=== chain verification — if this is not OK, STOP ==="
openssl verify -CAfile ga-ota-root-ca.pem -no-CApath ga-ota-signing.pem
echo
echo "=== ROOT CA — goes into every device keyring (ota/rel-ca.pem) ==="
openssl x509 -in ga-ota-root-ca.pem -noout -subject -enddate -fingerprint -sha256
echo "=== SIGNING CERT — signs bundles, stays on the builder (cert.pem) ==="
openssl x509 -in ga-ota-signing.pem -noout -subject -issuer -enddate -fingerprint -sha256
echo
echo "Next: back up ga-ota-root-ca.key OFF this machine, then delete it here."
echo "      Installation + rollout order: docs/RAUC-KEYRING.md"
