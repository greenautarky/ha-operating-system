include $(sort $(wildcard $(BR2_EXTERNAL_DSGW210_PATH)/package/*/*.mk))

# --- Data-partition bake (GA layer, patches 0131/0133) ----------------------
# BOSv1.6 dev bake: this board bakes EVERY image (Supervisor, plugins, Core,
# add-ons), all aarch64, from haos-version line/1.6/dev.json. Core 2026.10 needs
# Supervisor 2026.10 (#1186): never pair it with 2025.11.
GA_HASSIO_SKIP_IMAGES =
# Board pins (patch 0133): what the bake compares the channel with, instead of
# the iHost pins in version.yaml. They MUST equal dev.json (supervisor, core).
# Supervisor 2026.10.5.4 = 5.3 + the F3 pull stall timeout (300 s); aarch64 image tag == io.hass.version label.
GA_HASSIO_SUPERVISOR_PIN = 2026.10.5.4
# Core = the GA aarch64 release build 2026.10.4.6 (sha256:8b2bb4d2..., mariadb CVE rebuild 2026-11-23; before: 2026.10.4.5 sha256:e4e2cd81..., io.hass.version
# 2026.10.4.5, arch aarch64; = 2026.10.4.4 rebuilt on the 2026-11-18 Debian refresh,
# CVE-2026-99306). NOT a -dev tag: the Supervisor rates 2026.10.4.3-dev
# AwesomeVersion UNKNOWN, so it ignores the baked image (Odoo #1985).
GA_HASSIO_CORE_PIN = 2026.10.4.6
# The iHost's add-on set minus ga_ihosthardwarecontrol (armv7-only), see the file.
HASSIO_ADDON_IMAGES_JSON = $(BR2_EXTERNAL_DSGW210_PATH)/addon-images.json
