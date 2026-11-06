# LINUX_OVERRIDE_SRCDIR = /linux

# Included before package/*/*.mk (BR2_PACKAGE_OVERRIDE_FILE), which the Go floor
# needs: see buildroot-external/go-floor.mk.
include $(call qstrip,$(BR2_EXTERNAL_HASSOS_PATH))/go-floor.mk
# xz floor (host-xz and xz): see buildroot-external/xz-floor.mk.
include $(call qstrip,$(BR2_EXTERNAL_HASSOS_PATH))/xz-floor.mk
