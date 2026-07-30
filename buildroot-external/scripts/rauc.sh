#!/bin/bash
set -e


# Which signing material and which trust anchor this build uses.
#
# Until 2026-07-30 there was no separation at all: /build/key.pem was used
# unconditionally, and ota/dev-ca.pem was a SYMLINK to ota/rel-ca.pem. So a
# `dev` build signed with the PRODUCTION key against the PRODUCTION anchor, and
# produced a bundle every device in the field would install. The label said dev;
# the trust said prod.
#
# That is a real hole, not a tidiness issue. The keyring is not overlay-backed —
# it moves only by OTA or reflash — so whatever ships in 1.3.0 is a multi-year
# commitment across the fleet. Separating afterwards costs a fleet operation.
#
# Now: dev material signs dev images and production devices REJECT it, which is
# what the word is supposed to mean. Testing the production chain still requires
# a prod build, exactly as before — nothing is lost, the boundary is gained.
# The signal is GA_ENV, not DEPLOYMENT.
#
# DEPLOYMENT lives in buildroot-external/meta and is hardcoded "production" —
# it does not change between a dev and a prod build. ga_build.sh distinguishes
# them with GA_ENV (exported alongside GA_BUILD_TIMESTAMP and GA_RELEASE, and
# already consumed by post-build.sh for /etc/os-release).
#
# My first version of this keyed on DEPLOYMENT and was therefore inert: a dev
# build would have passed a preflight asking for the dev key and then signed
# with the PRODUCTION one — worse than no separation, because it looks
# separated. Caught by running the guard red before trusting it.
#
# Default is dev. If the signal is missing, the safe answer is the material
# whose blast radius is one bench, not the fleet.
function ga_is_prod() { [ "${GA_ENV:-dev}" = "prod" ]; }

# Signing material comes from /secrets, a dedicated read-only mount — NOT from
# /build.
#
# /build is the bind-mounted source checkout. Keeping the OTA signing keys there
# put them inside a directory that a --privileged container gets wholesale, that
# `git clean -xdf` walks, and that the CI runner's own user can rename or
# replace. The keys being gitignored stopped them being committed; it never
# stopped any of that. A separate mount is the actual boundary.
#
# The fallback to /build is deliberate, temporary, and LOUD. It exists so this
# change can land and be proven by a real build before the originals are
# removed — not so that the old path keeps quietly working. Rule: a fallback
# you cannot hear is a configuration error that becomes an outage nobody sees.
GA_SECRETS_DIR="${GA_SECRETS_DIR:-/secrets}"

# $1 = path under /secrets   $2 = legacy path under /build
function _ga_secret_path() {
    local want="${GA_SECRETS_DIR}/$1" legacy="$2"
    if [ -f "${want}" ]; then
        echo "${want}"
        return 0
    fi
    if [ -f "${legacy}" ]; then
        echo "WARNING: signing material read from ${legacy} — the bind-mounted" >&2
        echo "         source checkout. Expected ${want}. The build host is" >&2
        echo "         missing the read-only secrets mount; fix that rather" >&2
        echo "         than relying on this path." >&2
        echo "${legacy}"
        return 0
    fi
    # Neither: emit the EXPECTED path. prepare_rauc_signing() refuses on a
    # missing prod key, and a non-existent path is what makes it refuse.
    echo "${want}"
}

function ga_signing_key() {
    if ga_is_prod; then _ga_secret_path "key.pem"                 "/build/key.pem"
    else                _ga_secret_path "dev-ca/dev-signing.key"  "/build/dev-key.pem"; fi
}
function ga_signing_cert() {
    if ga_is_prod; then _ga_secret_path "cert.pem"                "/build/cert.pem"
    else                _ga_secret_path "dev-ca/dev-signing.pem"  "/build/dev-cert.pem"; fi
}
function ga_base_ca() {
    if ga_is_prod; then
        echo "${BR2_EXTERNAL_HASSOS_PATH}/ota/rel-ca.pem"
    else
        echo "${BR2_EXTERNAL_HASSOS_PATH}/ota/dev-ca.pem"
    fi
}

function prepare_rauc_signing() {
    local key cert
    key="$(ga_signing_key)"
    cert="$(ga_signing_cert)"

    if [ ! -f "${key}" ]; then
        if ! ga_is_prod; then
            # A throwaway self-signed cert is acceptable here and only here: it
            # cannot chain to the dev CA, so install_rauc_certs() appends it and
            # the image trusts exactly the thing that signed it. That image is a
            # dev image and no production device will take its bundles.
            echo "No dev signing key at ${key} — generating a throwaway self-signed certificate"
            "${BR2_EXTERNAL_HASSOS_PATH}"/scripts/generate-signing-key.sh "${cert}" "${key}"
        else
            # NEVER silently self-sign a production build. That is how the
            # pre-2026-07-29 keyring came to trust a throwaway certificate as a
            # fleet anchor, with one line in the build log as the only trace.
            echo "FATAL: production build but no signing key at ${key}." >&2
            echo "       Refusing to generate one — a self-signed key here becomes a" >&2
            echo "       fleet-wide trust anchor. Stage the real key or build with" >&2
            echo "       DEPLOYMENT=development." >&2
            exit 1
        fi
    fi
}


function write_rauc_config() {
    mkdir -p "${TARGET_DIR}/etc/rauc"

    local ota_compatible
    ota_compatible="$(hassos_rauc_compatible)"

    export ota_compatible
    export BOOTLOADER PARTITION_TABLE_TYPE BOOT_SPL

    (
        "${HOST_DIR}/bin/tempio" \
            -template "${BR2_EXTERNAL_HASSOS_PATH}/ota/system.conf.gtpl"
    ) > "${TARGET_DIR}/etc/rauc/system.conf"
}


function install_rauc_certs() {
    local cert base_ca
    cert="$(ga_signing_cert)"
    base_ca="$(ga_base_ca)"

    cp "${base_ca}" "${TARGET_DIR}/etc/rauc/keyring.pem"

    # Append the signing cert only when it does not chain to the anchor we just
    # installed. Verified against THAT anchor, not against dev-ca.pem for both
    # deployments — checking a prod cert against the dev CA is how a mismatch
    # would silently append a production certificate to a dev keyring.
    if ! openssl verify -CAfile "${base_ca}" -no-CApath "${cert}"; then
        echo "Adding self-signed certificate to keyring."
        openssl x509 -in "${cert}" -text >> "${TARGET_DIR}/etc/rauc/keyring.pem"
    fi

    # The retired pre-2026-03-27 ("F13") signing CA is DELETED, not gated.
    #
    # It used to be re-added here behind GA_LEGACY_CA_BRIDGE so pre-rotation
    # devices could still verify current OTAs. That cert is a self-signed
    # CA:TRUE root valid until 2035 and system.conf has no check-crl, so
    # trusting it fleet-wide had no revocation path — it effectively un-did the
    # rotation. Operator decision 2026-07-30: the remaining pre-cut devices are
    # being swapped, not bridged, so the material goes away entirely.
    #
    # Deleting beats keeping-it-off: a flag can be flipped by anyone who finds
    # the cert sitting next to it, and KEYRING-06 only defended the PROD path.
    # With no cert and no flag, re-trusting the retired CA takes a deliberate act
    # that has to reintroduce both.
    #
    # This does NOT remove the bridge-FORWARD path for old devices. That works
    # the other way round — sign a new image with the OLD KEY, which is archived
    # off the builder (2026-07-30) and deliberately not destroyed. It never
    # needed this cert in the keyring.
}


function install_bootloader_config() {
    if [ "${BOOTLOADER}" == "uboot" ]; then
        # shellcheck disable=SC1117
        echo -e "/dev/disk/by-partlabel/hassos-bootstate\t0x0000\t${BOOT_ENV_SIZE}" > "${TARGET_DIR}/etc/fw_env.config"
    fi

    # Fix MBR
    if [ "${PARTITION_TABLE_TYPE}" == "mbr" ]; then
        mkdir -p "${TARGET_DIR}/usr/lib/udev/rules.d"
        cp -f "${BR2_EXTERNAL_HASSOS_PATH}/bootloader/mbr-part.rules" "${TARGET_DIR}/usr/lib/udev/rules.d/"
    fi
}
