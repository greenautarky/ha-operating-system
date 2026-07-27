#!/bin/bash
set -e


function prepare_rauc_signing() {
    local key="/build/key.pem"
    local cert="/build/cert.pem"

    if [ ! -f "${key}" ]; then
        echo "Generating a self-signed certificate for development"
        "${BR2_EXTERNAL_HASSOS_PATH}"/scripts/generate-signing-key.sh "${cert}" "${key}"
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


# add_legacy_ca_if_enabled <keyring> <legacy-cert>
# Bake the retired pre-2026-03-27 ("F13") signing CA into <keyring>, but ONLY
# when GA_LEGACY_CA_BRIDGE=true (see buildroot-external/meta). That cert is a
# self-signed CA:TRUE root that stays valid until 2035, and system.conf has no
# check-crl, so trusting it fleet-wide has NO revocation path — it effectively
# un-does the 2026-03-27 key rotation. It is therefore an explicit, auditable
# opt-in kept only while pre-rotation devices may still be in the field (as of
# 2026-07-27 the mesh still shows >=16 active legacy-OS devices). Secure default:
# unset/anything-but-true => NOT baked. See KB "Fleet migration: retired trust
# anchors (legacy RAUC CA + shared SSH key)". [Vuln-3]
function add_legacy_ca_if_enabled() {
    local keyring="$1" legacy="$2"
    if [ "${GA_LEGACY_CA_BRIDGE:-false}" != "true" ]; then
        echo "Legacy CA bridge NOT baked (GA_LEGACY_CA_BRIDGE=${GA_LEGACY_CA_BRIDGE:-unset}) — retired signing CA not trusted."
        return 0
    fi
    if [ ! -f "${legacy}" ]; then
        echo "WARN: GA_LEGACY_CA_BRIDGE=true but ${legacy} missing — nothing baked."
        return 0
    fi
    echo "Adding legacy (pre-2026-03-27) signing cert to keyring (F13 bridge; GA_LEGACY_CA_BRIDGE=true)."
    openssl x509 -in "${legacy}" -text >> "${keyring}"
}


function install_rauc_certs() {
    local cert="/build/cert.pem"

    if [ "${DEPLOYMENT}" == "development" ]; then
        # Contains development and release certificate
        cp "${BR2_EXTERNAL_HASSOS_PATH}/ota/dev-ca.pem" "${TARGET_DIR}/etc/rauc/keyring.pem"
    else
        cp "${BR2_EXTERNAL_HASSOS_PATH}/ota/rel-ca.pem" "${TARGET_DIR}/etc/rauc/keyring.pem"
    fi

    # Add local self-signed certificate (if not trusted by the dev or release
    # certificate it is a self-signed certificate, dev-ca.pem contains both)
    if ! openssl verify -CAfile "${BR2_EXTERNAL_HASSOS_PATH}/ota/dev-ca.pem" -no-CApath "${cert}"; then
        echo "Adding self-signed certificate to keyring."
        openssl x509 -in "${cert}" -text >> "${TARGET_DIR}/etc/rauc/keyring.pem"
    fi

    # F13 legacy CA bridge (2026-06-05) — GATED behind GA_LEGACY_CA_BRIDGE.
    # Re-trusts the retired pre-2026-03-27 signing CA fleet-wide (no revocation
    # path). Without it, a device provisioned before the ga-builder cert
    # rotation cannot verify OTAs signed by the current key (the build cert and
    # its baked-in keyring share only a CN, not a key). Keep enabled only while
    # such devices remain in the field; the goal is to drop it after a field
    # audit. Legacy cert fingerprint:
    # 01:E7:CE:81:49:6B:75:43:22:3C:8B:31:29:4C:78:AB:D3:02:7F:FE:62:7A:B5:B6:28:AF:73:83:E1:21:BC:F7
    add_legacy_ca_if_enabled \
        "${TARGET_DIR}/etc/rauc/keyring.pem" \
        "${BR2_EXTERNAL_HASSOS_PATH}/ota/legacy-signing-cert.pem"
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
