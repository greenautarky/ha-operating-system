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
    # THE MARKER MUST BE REMOVED BEFORE A DEVICE SHIPS, and since 2026-09-08
    # something actually removes it: ga-ethernet-retire.path runs
    # `ga-manage-ethernet retire` when ga_manager writes /share/.ga_converged,
    # which is the end of the normal provisioning run. The paragraph below
    # describes the manual fallback for a device that never converges.
    #
    # tests/ga_tests/ethernet_force is the exit gate that proves it — including
    # the part that is easy to miss: deleting the file changes nothing until the
    # device reboots, so the gate reads the OS's own status file as well as the
    # filesystem, and keeps the two claims apart.
    #
    # An earlier version of this comment said the PROVISIONER removed the file
    # at the end of its run. It never did: measured against origin on
    # 2026-09-08, no stage, no job and no provision-verify check named this file
    # anywhere. Every unit built since 2026-07-30 therefore shipped with the
    # override live (Odoo #750, and the trigger for #753).
    #
    #   remove:  rm -f /mnt/boot/ga-ethernet-force && reboot
    #   verify:  sh tests/ga_tests/ethernet_force/test.sh   (on the device)
    #
    # THE PARAGRAPH THAT USED TO STAND HERE WAS BACKWARDS, and it is worth
    # keeping the correction rather than the silence. It read: "Partly
    # self-limiting: the RAUC install_boot hook reinstalls this partition and
    # preserves only *.txt and grubenv, so the first OTA drops the marker."
    #
    # The hook does reinstall the partition — from the BUNDLE, which carried a
    # copy of this very file, because both the .img and the .raucb were built
    # from one boot.vfat. So an OTA did not drop the marker, it RESTORED it, on
    # every device it reached. Measured on the rc43 bundle 2026-09-19:
    #   unsquashfs …raucb -> boot.vfat -> `GA-ETH~1  112  ga-ethernet-force`
    # Harmless only while ga-ethernet-retire.path beat ga-ethernet-guard.service
    # to it; #582 fixed that race and turned a dormant bug into a fleet-wide
    # posture change nobody had decided on.
    #
    # Since then the bundle gets its own marker-free boot image (boot-ota.vfat,
    # see buildroot-external/genimage/images-boot-ota.cfg), so this file now
    # reaches devices by FLASH ONLY. BLD-ETH-01 in run_build_tests.sh asserts
    # both halves against the real artifacts on every build.
    #
    # Which leaves the durable switch where it belongs — with the fleet, not
    # the image: ga_manager's `ethernet.force_enabled` writes an add-on-private
    # marker that survives every reboot and is cleared only when the
    # fleet-manager says so. Provisioning sets it while the cable is still the
    # uplink; after that this file has done its job and retire removes it.
    #
    # Re-add it on an already-deployed device with:
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