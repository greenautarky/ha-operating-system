#!/bin/bash
# shellcheck disable=SC2155

function haos_pre_image() {
    local BOOT_DATA="$(path_boot_dir)"

    cp "${BINARIES_DIR}/boot.scr" "${BOOT_DATA}/boot.scr"
    cp "${BINARIES_DIR}"/*.dtb "${BOOT_DATA}/"

    cp "${BOARD_DIR}/boot-env.txt" "${BOOT_DATA}/haos-config.txt"
    cp "${BOARD_DIR}/cmdline.txt" "${BOOT_DATA}/cmdline.txt"

    # ga-ethernet-force: Ethernet up for provisioning, by default. The Ethernet
    # policy (ADR-0034) keeps the wired NIC down unless forced; provisioning runs
    # over the cable before the device has an identity, so the image carries the
    # marker, as on the iHost. ga-ethernet-retire.path removes it once ga_manager
    # has converged (see buildroot-ihost/board/sonoff/ihost/haos-hook.sh for the
    # full history and the exit gate, tests/ga_tests/ethernet_force). The RAUC
    # bundle gets its own marker-free boot image (boot-ota.vfat), so this file
    # reaches a device by flash only.
    printf 'set-by=image-build\nreason=provisioning over ethernet; REMOVE BEFORE SHIPPING\ngate=tests/ga_tests/ethernet_force\n' \
        > "${BOOT_DATA}/ga-ethernet-force"
}


function haos_post_image() {
    convert_disk_image_xz
}
