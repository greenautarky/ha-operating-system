[system]
compatible={{ env "ota_compatible" }}
mountprefix=/run/rauc
statusfile=/mnt/boot/rauc.db
{{- if eq (env "BOOTLOADER") "tryboot" }}
bootloader=custom
{{- else }}
bootloader={{ env "BOOTLOADER" }}
{{- end }}
{{- if eq (env "BOOTLOADER") "grub" }}
grubenv=/mnt/boot/EFI/BOOT/grubenv
{{- end }}

[handlers]
# The GA release floor: runs from THIS rootfs for every install, after the
# signature check, before any slot is written. See the script's header.
pre-install=/usr/lib/rauc/ga-release-floor
{{- if eq (env "BOOTLOADER") "tryboot" }}
bootloader-custom-backend=/usr/lib/rauc/rpi-tryboot.sh
{{- end }}

[keyring]
path=/etc/rauc/keyring.pem

[slot.boot.0]
device=/dev/disk/by-partlabel/hassos-boot
type=vfat
allow-mounted=true
{{- if eq (env "BOOT_SPL") "true" }}
[slot.spl.0]
device=/dev/disk/by-partlabel/hassos-boot
type=raw
{{- end }}

[slot.kernel.0]
device=/dev/disk/by-partlabel/hassos-kernel0
type=raw
bootname=A

[slot.rootfs.0]
device=/dev/disk/by-partlabel/hassos-system0
type=raw
parent=kernel.0

[slot.kernel.1]
device=/dev/disk/by-partlabel/hassos-kernel1
type=raw
bootname=B

[slot.rootfs.1]
device=/dev/disk/by-partlabel/hassos-system1
type=raw
parent=kernel.1
