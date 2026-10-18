# Included before package/*/*.mk (BR2_PACKAGE_OVERRIDE_FILE): the Go toolchain
# floor and the container runtime floor must be in place before the package
# infrastructure bakes the versions into build-dir names and stamp rules. Same
# two includes as the iHost board; scripts/check-container-floor.sh requires
# them in the local.mk of every board.
include $(call qstrip,$(BR2_EXTERNAL_GA_HAOS_PATH))/go-floor.mk
include $(call qstrip,$(BR2_EXTERNAL_GA_HAOS_PATH))/container-floor.mk
