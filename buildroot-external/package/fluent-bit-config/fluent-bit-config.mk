################################################################################
# Fluent Bit config + systemd wrapper
################################################################################

FLUENT_BIT_CONFIG_DEPENDENCIES = fluent-bit

define FLUENT_BIT_CONFIG_INSTALL_TARGET_CMDS
	# Install config directory
	mkdir -p $(TARGET_DIR)/etc/fluent-bit

	# Copy main config + parsers from this package
	$(INSTALL) -D -m 0644 $(FLUENT_BIT_CONFIG_PKGDIR)/fluent-bit.conf \
		$(TARGET_DIR)/etc/fluent-bit/fluent-bit.conf
	$(INSTALL) -D -m 0644 $(FLUENT_BIT_CONFIG_PKGDIR)/parsers.conf \
		$(TARGET_DIR)/etc/fluent-bit/parsers.conf

	# Install systemd service
	#$(INSTALL) -D -m 0644 $(FLUENT_BIT_CONFIG_PKGDIR)/fluent-bit.service \
	#	$(TARGET_DIR)/etc/systemd/system/fluent-bit.service

	# Enable at boot
	#mkdir -p $(TARGET_DIR)/etc/systemd/system/multi-user.target.wants
	#ln -sf ../fluent-bit.service \
	#	$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/fluent-bit.service
endef

$(eval $(generic-package))
