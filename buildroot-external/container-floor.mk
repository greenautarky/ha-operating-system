# Container runtime floor (GA carry, until the buildroot submodule pins versions >= the floors).
#
# HAOS 18.3's buildroot ships docker-engine 29.7.2, docker-cli 29.7.2 and
# containerd 2.3.3. Security releases are out for all three:
#   docker-engine / docker-cli 29.8.2   https://github.com/moby/moby/releases/tag/docker-v29.8.2
#   containerd 2.3.6                    https://github.com/containerd/containerd/releases/tag/v2.3.6
# Master (HAOS 16.3 line) already ships them through its buildroot pin; this
# file gives the 18.x line the same versions without a buildroot fork.
#
# SAME MECHANISM AS go-floor.mk: included BEFORE package/*/*.mk through
# BR2_PACKAGE_OVERRIDE_FILE (buildroot-ihost/local.mk); `override` wins over the
# package's own plain assignment, and the version is fixed before the package
# infrastructure bakes it into build-dir names and stamp rules. The tarball
# hashes are in patches/<pkg>/<pkg>.hash (BR2_GLOBAL_PATCH_DIR hash files).
# HAOS's bridge-subnet patch for docker-engine (0001, written for 29.7.2) does
# NOT apply to 29.8.2 without fuzz, and buildroot applies patches with none:
# buildroot-ihost/patches-haos/docker-engine/ carries the same patch rebased
# onto 29.8.2 (scripts/ihost/check-haos-patch-mirror.sh pins the upstream one).
#
# It is a FLOOR, not a pin: when the submodule moves to a version >= the floor
# the override switches itself off (sort -V), so a submodule bump can never
# downgrade a package. scripts/check-container-floor.sh holds this file, the
# hash files and the submodule together (CI gate container_floor).
# Remove a line (and its hash file) once the submodule pins >= the floor.
#
# Format: <MAKE_PREFIX>:<buildroot package dir>:<floor version>
GA_CONTAINER_FLOORS = \
	DOCKER_ENGINE:docker-engine:29.8.2 \
	DOCKER_CLI:docker-cli:29.8.2 \
	CONTAINERD:containerd:2.3.6

define GA_CONTAINER_FLOOR
GA_$(1)_SUBMODULE_VERSION := $$(shell sed -n -E 's/^$(1)_VERSION[[:space:]]*=[[:space:]]*([0-9]+(\.[0-9]+)*)[[:space:]]*$$$$/\1/p' $$(TOPDIR)/package/$(2)/$(2).mk | head -n 1)
ifeq ($$(GA_$(1)_SUBMODULE_VERSION),)
$$(error container-floor.mk: cannot read $(1)_VERSION from $$(TOPDIR)/package/$(2)/$(2).mk - refusing to guess the version)
endif
ifneq ($$(GA_$(1)_SUBMODULE_VERSION),$(3))
ifeq ($$(firstword $$(shell printf '%s\n%s\n' '$$(GA_$(1)_SUBMODULE_VERSION)' '$(3)' | sort -V)),$$(GA_$(1)_SUBMODULE_VERSION))
override $(1)_VERSION = $(3)
endif
endif
endef

$(foreach f,$(GA_CONTAINER_FLOORS),$(eval $(call GA_CONTAINER_FLOOR,$(word 1,$(subst :, ,$(f))),$(word 2,$(subst :, ,$(f))),$(word 3,$(subst :, ,$(f))))))
