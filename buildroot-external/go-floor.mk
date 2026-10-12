# Go toolchain floor (GA carry, until the buildroot submodule pins Go >= floor).
#
# The buildroot submodule pins GO_VERSION 1.26.8. GO-2026-6604 and GO-2026-6612
# (Go stdlib) are fixed in Go 1.26.9:
#   https://vuln.go.dev/ID/GO-2026-6604.json
#   https://vuln.go.dev/ID/GO-2026-6612.json
#   https://go.dev/doc/devel/release#go1.26.9
# Every Go binary in the rootfs (netbird, dockerd, containerd, runc, os-agent,
# telegraf, tempio) is built with that toolchain.
#
# WHY A MAKEFILE FRAGMENT AND NOT A PATCH: a patch cannot change a version, and
# the package infrastructure bakes the version into build-dir names and stamp
# rules when package/go/*.mk is evaluated. A later override (external.mk) fixes
# the variables but not the rules, and the extract step then fails. This file is
# therefore included BEFORE package/*/*.mk through BR2_PACKAGE_OVERRIDE_FILE
# (buildroot-ihost/local.mk), and `override` makes it win over go.mk's own
# GO_VERSION assignment. The tarball hashes for the floor are in
# patches/go-src/go-src.hash and patches/go-bin/go-bin.hash
# (BR2_GLOBAL_PATCH_DIR hash files).
#
# It is a FLOOR, not a pin: when the submodule moves to a newer Go, the override
# switches itself off (sort -V), so a submodule bump can never downgrade Go.
# scripts/lib/go-toolchain.sh reads the GA_GO_VERSION_FLOOR line below
# (ga_go_floor_version): the bake guard GOTC-01..04 and this override cannot
# disagree. Remove this file (and the include in local.mk) when the submodule
# pins Go >= the floor.
GA_GO_VERSION_FLOOR = 1.26.9

GA_GO_SUBMODULE_VERSION := $(shell sed -n -E 's/^GO_VERSION[[:space:]]*=[[:space:]]*([0-9]+\.[0-9]+(\.[0-9]+)?)[[:space:]]*$$/\1/p' $(TOPDIR)/package/go/go.mk | head -n 1)
ifeq ($(GA_GO_SUBMODULE_VERSION),)
$(error go-floor.mk: cannot read GO_VERSION from $(TOPDIR)/package/go/go.mk - refusing to guess the Go toolchain)
endif

ifneq ($(GA_GO_SUBMODULE_VERSION),$(GA_GO_VERSION_FLOOR))
ifeq ($(firstword $(shell printf '%s\n%s\n' '$(GA_GO_SUBMODULE_VERSION)' '$(GA_GO_VERSION_FLOOR)' | sort -V)),$(GA_GO_SUBMODULE_VERSION))
override GO_VERSION = $(GA_GO_VERSION_FLOOR)
endif
endif
