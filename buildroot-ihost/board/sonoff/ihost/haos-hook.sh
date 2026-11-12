#!/bin/bash
# shellcheck disable=SC2155
#
# HAOS 18.x board hook for the Sonoff iHost. 18.x names the hook API haos_*
# (hassos_* until 16.x) and has no disk_size_fixup/data_size_fixup: it shrinks
# the data image to its contents and grows it on the device at first boot.

function haos_pre_image() {
    local BOOT_DATA="$(path_boot_dir)"

    cp -t "${BOOT_DATA}" \
        "${BINARIES_DIR}/boot.scr" \
        "${BINARIES_DIR}/rv1126-sonoff-ihost.dtb" \
        "${BINARIES_DIR}/rv1109-sonoff-ihost.dtb"

    # ── vccio5 = 3.3 V variant for freshly flashed devices (Odoo #1900) ──────
    # The RMII/MDIO bank is physically 3.3 V (#1484, measured 2026-11-11); the
    # DTBs above keep the legacy 1.8 V setting that every existing device runs.
    # boot.scr loads the *-vccio5-3v3.dtb when haos-config.txt carries
    # ga_vccio5=3v3 OR no key at all (option B, Odoo #1981); ga_vccio5=1v8 keeps
    # these DTBs, and the RAUC install-check hook pins the running mode as that
    # key before an OTA (patches-haos/0113). haos-config.txt
    # is device-owned (the RAUC boot hook restores *.txt), so an OTA never
    # changes a device's setting. The generator changes exactly one property
    # and fails the build on anything else.
    local soc
    for soc in rv1126 rv1109; do
        FDTGET="${HOST_DIR}/bin/fdtget" FDTPUT="${HOST_DIR}/bin/fdtput" DTC="${HOST_DIR}/bin/dtc" \
            "${BOARD_DIR}/make-vccio5-3v3-dtb.sh" \
            "${BINARIES_DIR}/${soc}-sonoff-ihost.dtb" \
            "${BOOT_DATA}/${soc}-sonoff-ihost-vccio5-3v3.dtb" || exit 1
    done

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
    # `ga-manage-ethernet retire-if-converged` when ga_manager writes its
    # converged marker into its own data directory (ADR-0041),
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


function haos_post_image() {
    convert_disk_image_xz
}
