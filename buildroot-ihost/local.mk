# LINUX_OVERRIDE_SRCDIR = /linux

# Included before package/*/*.mk (BR2_PACKAGE_OVERRIDE_FILE), which the Go floor
# needs: see buildroot-external/go-floor.mk.
include $(call qstrip,$(BR2_EXTERNAL_GA_HAOS_PATH))/go-floor.mk
# Container runtime floor (docker-engine, docker-cli, containerd): see
# buildroot-external/container-floor.mk. Same include point as the Go floor.
include $(call qstrip,$(BR2_EXTERNAL_GA_HAOS_PATH))/container-floor.mk
