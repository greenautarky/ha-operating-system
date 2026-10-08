[update]
compatible={{ env "ota_compatible" }}
version={{ env "ota_version" }}
{{- if env "ota_ga_release" }}

# The GA release this bundle's rootfs carries in /etc/ga-release. A device's
# RAUC pre-install handler (/usr/lib/rauc/ga-release-floor) refuses a bundle
# whose release is older than its own, or that has none. The HAOS version
# above cannot order GA releases: it was 16.3.1.9 from BOSv1.2.15 to
# BOSv1.5.0-rc1, and it does not move with every release.
[meta.ga]
release={{ env "ota_ga_release" }}
{{- end }}

[bundle]
format=verity

[hooks]
filename=hook
hooks=install-check;

[image.boot]
filename=boot.vfat
hooks=install;

[image.kernel]
filename=kernel.img
{{- if eq (env "BOOTLOADER") "tryboot" }}
hooks=post-install;
{{- end }}

[image.rootfs]
filename=rootfs.img

{{- if eq (env "BOOT_SPL") "true" }}
[image.spl]
filename=spl.img
hooks=install
{{- end }}
