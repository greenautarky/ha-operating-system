#!/bin/bash
# shellcheck disable=SC2155
#
# QEMU CI board hook — mirrors `board/pc/ova/hassos-hook.sh` but emits
# only the artifact a qemu-CI run consumes (raw .img -> qcow2 -> xz).
#
# Why a separate hook instead of re-using ova/:
#   - The ova path produces vmdk + vhdx + vdi + ova alongside qcow2 for
#     VM-deployment use-cases (VMware/Hyper-V/VirtualBox/vSphere). None
#     of those are useful for CI and they add ~30s + ~600MB per build.
#   - Cleaner separation: changes to the ova/ deployment artifact format
#     never touch CI, and vice-versa.

function hassos_pre_image() {
    local BOOT_DATA="$(path_boot_dir)"
    local EFIPART_DATA="${BINARIES_DIR}/efi-part"

    mkdir -p "${BOOT_DATA}/EFI/BOOT"

    # `board/pc/grub.cfg` is shared between pc/ova, pc/generic-x86-64, and
    # us — same EFI boot + RAUC slot switch logic.
    cp "${BOARD_DIR}/../grub.cfg" "${EFIPART_DATA}/EFI/BOOT/grub.cfg"
    cp "${BOARD_DIR}/cmdline.txt" "${EFIPART_DATA}/cmdline.txt"
    grub-editenv "${EFIPART_DATA}/EFI/BOOT/grubenv" create
    grub-editenv "${EFIPART_DATA}/EFI/BOOT/grubenv" set ORDER="A B"
    grub-editenv "${EFIPART_DATA}/EFI/BOOT/grubenv" set A_OK=1
    grub-editenv "${EFIPART_DATA}/EFI/BOOT/grubenv" set A_TRY=0

    cp -r "${EFIPART_DATA}/"* "${BOOT_DATA}/"
}


function hassos_post_image() {
    local hdd_img="$(hassos_image_name img)"

    # qcow2 is what qemu-system-x86_64 consumes natively; .xz keeps the
    # artifact upload contract consistent with the iHost .img.xz path.
    convert_disk_image_virtual qcow2
    convert_disk_image_xz qcow2

    # The raw .img is just an intermediate — drop it so we don't ship
    # 8G of zeroes as a build artifact.
    rm -f "${hdd_img}"
}
