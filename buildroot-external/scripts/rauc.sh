#!/bin/bash
set -e


# Signing material and trust anchor: ONE of each (ADR-0027 Amendment 1, D9).
#
# The keyring gets the OTA root CA (ota/rel-ca.pem); bundles are signed with the
# one signing certificate issued under that root. There is no build-mode
# selector any more: the dev key protected nothing in the fleet (no device
# trusted it) and the selector around it produced one real incident, where a
# production keyring came to trust a self-signed certificate.
#
# Signing material is read from /secrets, a dedicated read-only mount, and from
# NOWHERE else. /build is the bind-mounted source checkout: a --privileged
# container gets it wholesale, `git clean -xdf` walks it, and the CI runner's
# own user can rename or replace files in it. The fallback to it that bridged
# the move to /secrets is gone; a missing mount now fails the build.
GA_SECRETS_DIR="${GA_SECRETS_DIR:-/secrets}"

function ga_signing_key()  { echo "${GA_SECRETS_DIR}/key.pem"; }
function ga_signing_cert() { echo "${GA_SECRETS_DIR}/cert.pem"; }
function ga_base_ca()      { echo "${BR2_EXTERNAL_HASSOS_PATH}/ota/rel-ca.pem"; }

function prepare_rauc_signing() {
    local key cert
    key="$(ga_signing_key)"
    cert="$(ga_signing_cert)"

    # NEVER generate a key here. A self-signed certificate created on the fly
    # becomes a fleet trust anchor via install_rauc_certs(), with one build-log
    # line as the only trace — that is how a production keyring once came to
    # trust a throwaway certificate.
    if [ ! -f "${key}" ] || [ ! -f "${cert}" ]; then
        echo "FATAL: RAUC signing material missing: ${key} / ${cert}." >&2
        echo "       It is read from the read-only secrets mount only" >&2
        echo "       (docker run -v <secrets>:${GA_SECRETS_DIR}:ro). Refusing to" >&2
        echo "       generate a key or to read one from the source checkout." >&2
        exit 1
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

    # The signing cert must chain to the root. If it does not, it used to be
    # appended as a second anchor; KEYRING-02 now fails any keyring that holds
    # more than the pinned root, so a non-chaining cert is caught at the end of
    # the build. Appending is kept (rather than failing here) so that audit
    # sees — and names — exactly what a mis-issued cert would have shipped.
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
    # the cert sitting next to it.
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
