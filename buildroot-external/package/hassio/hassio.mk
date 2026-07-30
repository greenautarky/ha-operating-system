################################################################################
#
# HAOS
#
################################################################################

HASSIO_VERSION = 1.0.0
HASSIO_LICENSE = Apache License 2.0
# HASSIO_LICENSE_FILES = $(BR2_EXTERNAL_HASSOS_PATH)/../LICENSE
HASSIO_SITE = $(BR2_EXTERNAL_HASSOS_PATH)/package/hassio
HASSIO_SITE_METHOD = local
# The channel the BUILD bakes from. This MUST be the same branch the devices
# poll, or every freshly flashed unit bricks its own provisioning — see below.
#
# It used to point at release/v1.2-rebuild, a "V1.2-clean WIP" pointer whose own
# comment said "revert to main/ at the V1.2 promote". That promote never
# happened (v1.2 reached rc40 without ever being released), the branch went
# stale on 2026-06-01, and the temporary pointer became permanent.
#
# What that cost, measured on K31 2026-07-30: the branch pins supervisor
# 2025.11.4.5, so the build baked 4.5, while devices poll main and see 4.6.
# Supervisor therefore reports update_available=true on first boot, which trips
# its `supervisor_updated` job condition and BLOCKS StoreManager.add_repository.
# ga-bootstrap cannot register the vibe_addons store, no add-on installs,
# ga_manager never runs, the device never finishes provisioning — and nothing
# reports an error. The device boots, answers on serial, and is inert.
#
# Keep this pointing where the fleet points.
HASSIO_VERSION_URL ?= "https://raw.githubusercontent.com/greenautarky/haos-version/main/"
ifeq ($(BR2_PACKAGE_HASSIO_CHANNEL_STABLE),y)
HASSIO_VERSION_CHANNEL = "stable"
else ifeq ($(BR2_PACKAGE_HASSIO_CHANNEL_BETA),y)
HASSIO_VERSION_CHANNEL = "beta"
else ifeq ($(BR2_PACKAGE_HASSIO_CHANNEL_DEV),y)
HASSIO_VERSION_CHANNEL = "dev"
endif

HASSIO_CONTAINER_IMAGES_ARCH = supervisor dns audio cli multicast observer core

ifeq ($(BR2_PACKAGE_HASSIO_FULL_CORE),y)
HASSIO_CORE_VERSION = $(shell curl -s $(HASSIO_VERSION_URL)$(HASSIO_VERSION_CHANNEL)".json" | jq .homeassistant | jq .${BR2_PACKAGE_HASSIO_MACHINE})
else
HASSIO_CORE_VERSION = "landingpage"
endif

define HASSIO_CONFIGURE_CMDS
	# HomeAssistantOS Deploy only landing page for "core" by setting version to "landingpage", but we are using the full core image whether BR2_PACKAGE_HASSIO_FULL_CORE is set or not
	curl -s $(HASSIO_VERSION_URL)$(HASSIO_VERSION_CHANNEL)".json" | jq '.core = $(HASSIO_CORE_VERSION)' > $(@D)/version.json;
	# Validate version.json: reject "latest" and wrong registries (catches stale stable.json)
	# V1.2-clean: Core is STOCK upstream (ghcr.io/home-assistant/*) — GA value
	# moved to a custom_component. Only the Supervisor stays a GA image.
	@VJ=$(@D)/version.json; \
	SUP=$$(jq -r '.supervisor' $$VJ); \
	CORE=$$(jq -r '.core' $$VJ); \
	TINKER=$$(jq -r '.homeassistant.tinker // .homeassistant.default' $$VJ); \
	SUP_IMG=$$(jq -r '.images.supervisor' $$VJ); \
	CORE_IMG=$$(jq -r '.images.core' $$VJ); \
	FAIL=0; \
	if [ "$$SUP" = "latest" ] || [ -z "$$SUP" ]; then echo "ERROR: version.json supervisor='$$SUP' (must be pinned version)"; FAIL=1; fi; \
	if [ "$$CORE" = "latest" ] || [ -z "$$CORE" ]; then echo "ERROR: version.json core='$$CORE' (must be pinned version)"; FAIL=1; fi; \
	if [ "$$TINKER" = "latest" ] || [ -z "$$TINKER" ]; then echo "ERROR: version.json tinker='$$TINKER' (must be pinned version)"; FAIL=1; fi; \
	if ! echo "$$SUP_IMG" | grep -q greenautarky; then echo "ERROR: version.json supervisor image='$$SUP_IMG' (must use greenautarky)"; FAIL=1; fi; \
	if ! echo "$$CORE_IMG" | grep -qE '^ghcr\.io/home-assistant/'; then echo "ERROR: version.json core image='$$CORE_IMG' (V1.2-clean: Core must be stock ghcr.io/home-assistant/*)"; FAIL=1; fi; \
	PIN=$$(sed -nE 's/^[[:space:]]*homeassistant_supervisor:[[:space:]]*"?([^"[:space:]#]+)"?.*/\1/p' $(BR2_EXTERNAL_HASSOS_PATH)/../version.yaml | head -1); \
	if [ -n "$$PIN" ] && [ "$$SUP" != "$$PIN" ]; then \
	  echo "ERROR: version.json supervisor='$$SUP' but version.yaml pins '$$PIN'"; \
	  echo "       The BAKED supervisor would differ from the pin. A device whose"; \
	  echo "       supervisor is older than the channel sets update_available=true,"; \
	  echo "       which blocks StoreManager and leaves the device unprovisionable."; \
	  echo "       Check HASSIO_VERSION_URL points at the branch the fleet polls."; \
	  FAIL=1; \
	fi; \
	if [ $$FAIL -ne 0 ]; then echo "FATAL: version.json validation failed — check haos-version stable.json"; exit 1; fi; \
	echo "version.json validated: supervisor=$$SUP core=$$CORE tinker=$$TINKER (pin=$$PIN)"
endef

define HASSIO_BUILD_CMDS
	$(Q)mkdir -p $(@D)/images
	$(Q)mkdir -p $(HASSIO_DL_DIR)
	$(foreach image,$(HASSIO_CONTAINER_IMAGES_ARCH),\
		$(BR2_EXTERNAL_HASSOS_PATH)/package/hassio/fetch-container-image.sh \
			$(BR2_PACKAGE_HASSIO_ARCH) $(BR2_PACKAGE_HASSIO_MACHINE) $(@D)/version.json $(image) "$(HASSIO_DL_DIR)" "$(@D)/images"
	)
	$(BR2_EXTERNAL_HASSOS_PATH)/package/hassio/fetch-addon-images.sh \
		$(BR2_PACKAGE_HASSIO_ARCH) $(BR2_PACKAGE_HASSIO_MACHINE) \
		$(BR2_EXTERNAL_HASSOS_PATH)/package/hassio/addon-images.json \
		"$(HASSIO_DL_DIR)" "$(@D)/images"
endef

HASSIO_INSTALL_IMAGES = YES

define HASSIO_INSTALL_IMAGES_CMDS
	$(BR2_EXTERNAL_HASSOS_PATH)/package/hassio/create-data-partition.sh "$(@D)" "$(BINARIES_DIR)" "$(HASSIO_VERSION_CHANNEL)" "$(DOCKER_ENGINE_VERSION)" "$(BR2_PACKAGE_HASSIO_DATA_IMAGE_SIZE)";
endef

$(eval $(generic-package))
