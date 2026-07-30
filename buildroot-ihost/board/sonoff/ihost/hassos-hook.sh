#!/bin/bash
# shellcheck disable=SC2155

function hassos_pre_image() {
    local BOOT_DATA="$(path_boot_dir)"

    cp -t "${BOOT_DATA}" \
        "${BINARIES_DIR}/boot.scr" \
        "${BINARIES_DIR}/rv1126-sonoff-ihost.dtb" \
        "${BINARIES_DIR}/rv1109-sonoff-ihost.dtb"

    mkdir -p "${BOOT_DATA}/overlays"
    #cp "${BINARIES_DIR}"/*.dtbo "${BOOT_DATA}/overlays/"
    cp "${BOARD_DIR}/boot-env.txt" "${BOOT_DATA}/haos-config.txt"
    cp "${BOARD_DIR}/cmdline.txt" "${BOOT_DATA}/cmdline.txt"

    # ── ga-ethernet-force: Ethernet up for provisioning, by default ──────────
    # Operator decision 2026-07-30. Provisioning runs over Ethernet rather than
    # WiFi: no customer credentials exist yet, and a cable beats maintaining a
    # WLAN per provisioning bench. ga-manage-ethernet reads this marker and
    # brings eth0 up regardless of the onboarding consent state.
    #
    # THE MARKER MUST BE REMOVED BEFORE A DEVICE SHIPS. The provisioner does
    # that at the end of its run, and tests/ga_tests/ethernet_force is the exit
    # gate that proves it — including the part that is easy to miss: deleting
    # the file changes nothing until the device reboots, so the gate reads the
    # OS's own status file, not just the filesystem.
    #
    #   remove:  rm -f /mnt/boot/ga-ethernet-force && reboot
    #   verify:  sh tests/ga_tests/ethernet_force/test.sh   (on the device)
    #
    # Partly self-limiting: the RAUC install_boot hook reinstalls this partition
    # and preserves only *.txt and grubenv, so the first OTA drops the marker.
    # Convenient, NOT a substitute for removing it — a unit that ships before
    # its first OTA still carries it.
    #
    # Re-add it after an OTA with:
    #   scripts/verify-sd.sh --flash --ethernet-force …   (at flash time), or
    #   touch /mnt/boot/ga-ethernet-force                 (on the device)
    printf 'set-by=image-build\nreason=provisioning over ethernet; REMOVE BEFORE SHIPPING\ngate=tests/ga_tests/ethernet_force\n' \
        > "${BOOT_DATA}/ga-ethernet-force"
}


function hassos_post_image() {
    convert_disk_image_xz
}


function disk_size_fixup() {
    if grep -q ^BR2_PACKAGE_HASSIO_FULL_CORE=y "${BASE_DIR}/.config"; then
        echo "${FULL_DISK_SIZE}"
    else
        echo "${DISK_SIZE}"
    fi
}

function data_size_fixup() {
    if grep -q ^BR2_PACKAGE_HASSIO_DATA_IMAGE_SIZE "${BASE_DIR}/.config"; then
        echo "${BR2_PACKAGE_HASSIO_DATA_IMAGE_SIZE}"
    else
        echo "1280M"
    fi
}