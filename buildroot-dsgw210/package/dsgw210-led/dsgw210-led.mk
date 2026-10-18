################################################################################
#
# dsgw210-led — builds `dsgw-led`, the DSGW-210 status-LED ring daemon +
# client (TM1929 at I2C 0x23 on /dev/i2c-0). Single C file, no deps,
# linked statically. Units: board/dusun/dsgw210/rootfs-overlay.
#
# Host unit test (mock I2C backend): make -C package/dsgw210-led/src test
#
################################################################################

DSGW210_LED_VERSION = 2.0
DSGW210_LED_SITE = $(BR2_EXTERNAL_DSGW210_PATH)/package/dsgw210-led/src
DSGW210_LED_SITE_METHOD = local
DSGW210_LED_LICENSE = GPL-2.0

define DSGW210_LED_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D) dsgw-led
endef

define DSGW210_LED_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/dsgw-led $(TARGET_DIR)/usr/bin/dsgw-led
	rm -f $(TARGET_DIR)/usr/bin/dsgw210-led
endef

$(eval $(generic-package))
