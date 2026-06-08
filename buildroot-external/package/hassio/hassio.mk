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
# The branch of greenautarky/haos-version this build follows. Read from
# version.yaml's `haos_version_branch:` key — single bump pattern, no
# hardcoded branch here. Fallback to `main` if the key is missing or
# version.yaml can't be read (e.g. out-of-tree builds).
#
# Build-time override still works via the command-line (`make
# HASSIO_VERSION_URL=…`) — that path is used by ga_build.sh's MAKE_OVERRIDES
# for staged rollouts (see scripts/ga_build.sh comment on MAKE_OVERRIDES).
#
# Why read at parse-time (`:=`, not `=`): `HASSIO_CORE_VERSION` below uses
# `$(shell curl … $(HASSIO_VERSION_URL))` and Buildroot dereferences it
# during top-level config — a recursive `=` would re-shell out per `$@`
# evaluation. Once-and-cached is what we want.
HASSIO_VERSION_BRANCH := $(shell sed -nE 's/^haos_version_branch:[[:space:]]*"?([^"#[:space:]]+)"?.*$$/\1/p' $(BR2_EXTERNAL_HASSOS_PATH)/../version.yaml 2>/dev/null | head -1)
ifeq ($(HASSIO_VERSION_BRANCH),)
HASSIO_VERSION_BRANCH := main
endif
HASSIO_VERSION_URL ?= "https://raw.githubusercontent.com/greenautarky/haos-version/$(HASSIO_VERSION_BRANCH)/"
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
	if [ $$FAIL -ne 0 ]; then echo "FATAL: version.json validation failed — check haos-version stable.json"; exit 1; fi; \
	echo "version.json validated: supervisor=$$SUP core=$$CORE tinker=$$TINKER"
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
