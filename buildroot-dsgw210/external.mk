include $(sort $(wildcard $(BR2_EXTERNAL_DSGW210_PATH)/package/*/*.mk))

# --- Data-partition bake (GA layer, patches 0131/0133) ----------------------
# BOSv1.6 dev bake: this board bakes EVERY image (Supervisor, plugins, Core,
# add-ons), all aarch64, from haos-version line/1.6/dev.json. Core 2026.10 needs
# Supervisor 2026.10 (#1186): never pair it with 2025.11.
GA_HASSIO_SKIP_IMAGES =
# Board pins (patch 0133): what the bake compares the channel with, instead of
# the iHost pins in version.yaml. They MUST equal dev.json (supervisor, core).
# Supervisor 2026.10.5.3 = 5.1 + auto_update=False default (#1615); aarch64 image tag == io.hass.version label.
GA_HASSIO_SUPERVISOR_PIN = 2026.10.5.3
# Core = the GA aarch64 release build 2026.10.4.4 (sha256:bb9db4d4..., io.hass.version
# 2026.10.4.4, arch aarch64). NOT a -dev tag: the Supervisor rates 2026.10.4.3-dev
# AwesomeVersion UNKNOWN, so it ignores the baked image (Odoo #1985).
GA_HASSIO_CORE_PIN = 2026.10.4.4
# The iHost's add-on set minus ga_ihosthardwarecontrol (armv7-only), see the file.
HASSIO_ADDON_IMAGES_JSON = $(BR2_EXTERNAL_DSGW210_PATH)/addon-images.json
