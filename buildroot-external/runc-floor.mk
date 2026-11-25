# runc floor (GA carry, until the buildroot submodule pins runc >= the floor).
#
# HAOS 18.4's buildroot pins runc 1.4.3. 1.4.4 fixes CVE-2026-119101
# (GHSA-g2c3-j8g3-7gpw, `runc restore` of a CRIU checkpoint; the device does not
# checkpoint containers) and moves to opencontainers/cgroups v0.1.0.
#
# Same mechanism and same PKGDIR redirect as xz-floor.mk: HAOS's six device
# patches live in the submodule's package/runc/, Buildroot applies them with no
# fuzz, and 0001 no longer applies to 1.4.4 (one context line of a vendored file).
# runc-floor/ holds the same six patches with that hunk rebased, and the hashes.
# scripts/check-runc-floor.sh pins the six upstream patches, so an upstream change
# forces a re-check. A FLOOR, not a pin: it switches itself off when the submodule
# reaches it. Remove this file, runc-floor/ and the local.mk includes then.
GA_RUNC_VERSION_FLOOR = 1.4.4
GA_RUNC_FLOOR_DIR := $(dir $(lastword $(MAKEFILE_LIST)))runc-floor

GA_RUNC_SUBMODULE_VERSION := $(shell sed -n -E 's/^RUNC_VERSION[[:space:]]*=[[:space:]]*([0-9]+(\.[0-9]+)*)[[:space:]]*$$/\1/p' $(TOPDIR)/package/runc/runc.mk | head -n 1)
ifeq ($(GA_RUNC_SUBMODULE_VERSION),)
$(error runc-floor.mk: cannot read RUNC_VERSION from $(TOPDIR)/package/runc/runc.mk - refusing to guess the version)
endif

ifneq ($(GA_RUNC_SUBMODULE_VERSION),$(GA_RUNC_VERSION_FLOOR))
ifeq ($(firstword $(shell printf '%s\n%s\n' '$(GA_RUNC_SUBMODULE_VERSION)' '$(GA_RUNC_VERSION_FLOOR)' | sort -V)),$(GA_RUNC_SUBMODULE_VERSION))
override RUNC_VERSION = $(GA_RUNC_VERSION_FLOOR)
override RUNC_PKGDIR = $(GA_RUNC_FLOOR_DIR)
override HOST_RUNC_PKGDIR = $(GA_RUNC_FLOOR_DIR)
endif
endif
