# xz floor (GA carry, until the buildroot submodule pins xz >= the floor).
#
# HAOS 18.4's buildroot (2025.02.19) pins XZ_VERSION 5.6.4 (plus backports of the
# 5.6.x fixes). Three published advisories name that version (fixed in 5.8.4):
#   GHSA-5qpq-xqfv-j9pg  GHSA-6cc8-p5mm-29w2  GHSA-x872-m794-cxhv
#   https://github.com/tukaani-project/xz/security/advisories
# xz is built twice (host-xz for the build tools: squashfs/erofs/RAUC bundle
# creation; xz for the target rootfs), both are lifted here.
#
# SAME MECHANISM AS go-floor.mk: included BEFORE package/*/*.mk through
# BR2_PACKAGE_OVERRIDE_FILE (each board's local.mk); `override` wins over the
# package's own plain assignment, so the version is fixed before the package
# infrastructure bakes it into build-dir names and stamp rules.
#
# EXTRA STEP xz NEEDS: the submodule's package/xz/ carries backports of fixes
# that 5.8.4 already contains (0001-0007 in HAOS 18.4). Buildroot applies every *.patch of
# <PKG>_PKGDIR with no fuzz and fails the build when one is already applied. A
# patch cannot be removed from a tree we do not push to, so <PKG>_PKGDIR is
# pointed at buildroot-external/xz-floor/ instead: it holds the hash file for
# 5.8.4 (tarball + licence files; the submodule's xz.hash names 5.6.4) and no
# patches. The tarball sha256 was checked against Lasse Collin's detached
# signature (key 3690C240CE51B4670D30AD1C38EE757D69184620).
#
# It is a FLOOR, not a pin: when the submodule moves to xz >= the floor the
# override switches itself off (sort -V), so a submodule bump can never
# downgrade xz. scripts/check-xz-floor.sh holds this file, the hash file, the
# board local.mk include and the submodule together (CI gate xz_floor).
# Remove this file, xz-floor/ and the local.mk include once the submodule pins
# xz >= the floor.
GA_XZ_VERSION_FLOOR = 5.8.4
GA_XZ_FLOOR_DIR := $(dir $(lastword $(MAKEFILE_LIST)))xz-floor

GA_XZ_SUBMODULE_VERSION := $(shell sed -n -E 's/^XZ_VERSION[[:space:]]*=[[:space:]]*([0-9]+(\.[0-9]+)*)[[:space:]]*$$/\1/p' $(TOPDIR)/package/xz/xz.mk | head -n 1)
ifeq ($(GA_XZ_SUBMODULE_VERSION),)
$(error xz-floor.mk: cannot read XZ_VERSION from $(TOPDIR)/package/xz/xz.mk - refusing to guess the version)
endif

ifneq ($(GA_XZ_SUBMODULE_VERSION),$(GA_XZ_VERSION_FLOOR))
ifeq ($(firstword $(shell printf '%s\n%s\n' '$(GA_XZ_SUBMODULE_VERSION)' '$(GA_XZ_VERSION_FLOOR)' | sort -V)),$(GA_XZ_SUBMODULE_VERSION))
override XZ_VERSION = $(GA_XZ_VERSION_FLOOR)
override XZ_PKGDIR = $(GA_XZ_FLOOR_DIR)
override HOST_XZ_PKGDIR = $(GA_XZ_FLOOR_DIR)
endif
endif
