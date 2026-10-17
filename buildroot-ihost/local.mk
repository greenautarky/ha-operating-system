# LINUX_OVERRIDE_SRCDIR = /linux

# Included before package/*/*.mk (BR2_PACKAGE_OVERRIDE_FILE), which the Go floor
# needs: see buildroot-external/go-floor.mk.
include $(call qstrip,$(BR2_EXTERNAL_GA_HAOS_PATH))/go-floor.mk
