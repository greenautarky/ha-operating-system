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

    # F13 fix (2026-06-05): also bake the LEGACY signing cert (used by
    # KIB-SONs provisioned before 2026-03-27 ga-builder cert rotation).
    # Without this, any device upgraded from the legacy stack would need
    # an explicit CA-bridge bind-mount (see RUNBOOK-LEGACY-CA-BRIDGE-MIGRATION.md
    # in ga-ihost-docs) on every future OTA, because the build's signing cert
    # and the device's baked-in keyring don't share a key (only a CN).
    # The legacy cert was extracted from K6's pre-migration keyring snapshot
    # (2026-06-05); SHA-256 fingerprint
    # 01:E7:CE:81:49:6B:75:43:22:3C:8B:31:29:4C:78:AB:D3:02:7F:FE:62:7A:B5:B6:28:AF:73:83:E1:21:BC:F7
    # valid 2025-09 to 2035-09. Drop this branch once the last legacy
    # device is decommissioned (track via fleet-manager devices.yaml).
    if [ -f "${BR2_EXTERNAL_HASSOS_PATH}/ota/legacy-signing-cert.pem" ]; then
        echo "Adding legacy (pre-2026-03-27) signing cert to keyring (F13 fix)."
        openssl x509 -in "${BR2_EXTERNAL_HASSOS_PATH}/ota/legacy-signing-cert.pem" -text >> "${TARGET_DIR}/etc/rauc/keyring.pem"
    fi
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
