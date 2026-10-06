HASSIO_VERSION_URL ?= "https://raw.githubusercontent.com/greenautarky/haos-version/main/"
define HASSIO_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/etc
	rm -f $(TARGET_DIR)/etc/ga-version-url
	printf '%s\n' "https://raw.githubusercontent.com/greenautarky/haos-version/candidate/stable-1.4/" > $(TARGET_DIR)/etc/ga-version-url
	chmod 0444 $(TARGET_DIR)/etc/ga-version-url
endef
