################################################################################
#
# ga-wlan-platdata — OOT kernel module for RTL8821CS bring-up on mainline
# kernels. Mirrors the Rockchip 4.4 BSP rfkill-wlan + rp_gpio late-rescan
# behaviour that mainline lacks. Bound to greenautarky,wlan-platdata in DT.
#
# The sources live in this package's src/ directory; site method 'local'
# copies them into the buildroot build dir at extract time.
#
################################################################################

GA_WLAN_PLATDATA_VERSION = 1.0
GA_WLAN_PLATDATA_SITE = $(BR2_EXTERNAL_DSGW210_PATH)/package/ga-wlan-platdata/src
GA_WLAN_PLATDATA_SITE_METHOD = local
GA_WLAN_PLATDATA_LICENSE = GPL-2.0

# kernel-module infra handles the actual build via the kernel's external
# module build system (make -C <kernel> M=<module>). It needs the kernel
# to be built first; declared automatically by inner-kernel-module.

# Install the .ko via the kernel's modules_install target — buildroot then
# picks it up as part of the regular linux package's rootfs population, so
# `modprobe ga_wlan_platdata` works after boot.
GA_WLAN_PLATDATA_MODULE_SUBDIRS = .

# Auto-load at boot: drop a modules-load.d snippet into the rootfs.
define GA_WLAN_PLATDATA_INSTALL_MODULES_LOAD_D
	mkdir -p $(TARGET_DIR)/etc/modules-load.d
	echo 'ga_wlan_platdata' > $(TARGET_DIR)/etc/modules-load.d/ga-wlan.conf
endef
GA_WLAN_PLATDATA_POST_INSTALL_TARGET_HOOKS += GA_WLAN_PLATDATA_INSTALL_MODULES_LOAD_D

$(eval $(kernel-module))
$(eval $(generic-package))
