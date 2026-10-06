HASSIO_VERSION_URL ?= "https://raw.githubusercontent.com/greenautarky/haos-version/release/v1.2-rebuild/"
define HASSIO_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/etc
	rm -f $(TARGET_DIR)/etc/ga-version-url
	printf '%s\n' $(HASSIO_VERSION_URL) > $(TARGET_DIR)/etc/ga-version-url
	chmod 0444 $(TARGET_DIR)/etc/ga-version-url
endef
