BUILDDIR:=$(shell pwd)

BUILDROOT=$(BUILDDIR)/buildroot
BUILDROOT_EXTERNAL=$(BUILDDIR)/buildroot-external
DEFCONFIG_DIR = $(BUILDROOT_EXTERNAL)/configs
BUILDROOT_IHOST_EXTERNAL=$(BUILDDIR)/buildroot-ihost
DEFCONFIG_IHOST_DIR = $(BUILDROOT_IHOST_EXTERNAL)/configs

TARGETS := $(notdir $(patsubst %_defconfig,%,$(wildcard $(DEFCONFIG_DIR)/*_defconfig $(DEFCONFIG_IHOST_DIR)/*_defconfig)))
TARGETS_CONFIG := $(notdir $(patsubst %_defconfig,%-config,$(wildcard $(DEFCONFIG_DIR)/*_defconfig $(DEFCONFIG_IHOST_DIR)/*_defconfig)))

# Set O variable if not already done on the command line
ifneq ("$(origin O)", "command line")
O := $(BUILDDIR)/output
else
override O := $(BUILDDIR)/$(O)
endif

################################################################################

SILENT := $(findstring s,$(word 1, $(MAKEFLAGS)))

define print
	$(if $(SILENT),,$(info $1))
endef

COLOR_STEP := $(shell tput smso 2>/dev/null)
COLOR_WARN := $(shell (tput setab 3; tput setaf 0) 2>/dev/null)
TERM_RESET := $(shell tput sgr0 2>/dev/null)

################################################################################

.NOTPARALLEL: $(TARGETS) $(TARGETS_CONFIG) default

.PHONY: $(TARGETS) $(TARGETS_CONFIG) default buildroot-help help

# fallback target when target undefined here is given
.DEFAULT:
	$(call print,$(COLOR_STEP)=== Falling back to Buildroot target '$@' ===$(TERM_RESET))
	$(MAKE) -C $(BUILDROOT) O=$(O) BR2_EXTERNAL=$(BUILDROOT_IHOST_EXTERNAL):$(BUILDROOT_EXTERNAL) "$@"

# default target when no target is given - must be first in Makefile
default:
	$(MAKE) -C $(BUILDROOT) O=$(O) BR2_EXTERNAL=$(BUILDROOT_IHOST_EXTERNAL):$(BUILDROOT_EXTERNAL)

$(TARGETS_CONFIG): %-config:
	@if [ -f $(O)/.config ] && (! grep -q 'BR2_DEFCONFIG="$(DEFCONFIG_DIR)/$*_defconfig"' $(O)/.config && ! grep -q 'BR2_DEFCONFIG="$(DEFCONFIG_IHOST_DIR)/$*_defconfig"' $(O)/.config); then \
		echo "$(COLOR_WARN)WARNING: Output directory '$(O)' already contains files for another target!$(TERM_RESET)"; \
		echo "         Before running build for a different target, run 'make distclean' first."; \
		echo ""; \
		bash -c 'read -t 10 -p "Waiting 10s, press enter to continue or Ctrl-C to abort..."' || true; \
	fi
	$(call print,$(COLOR_STEP)=== Using $*_defconfig ===$(TERM_RESET))
	$(MAKE) -C $(BUILDROOT) O=$(O) BR2_EXTERNAL=$(BUILDROOT_IHOST_EXTERNAL):$(BUILDROOT_EXTERNAL) "$*_defconfig"

$(TARGETS): %: %-config
	$(call print,$(COLOR_STEP)=== Building $@ ===$(TERM_RESET))
	$(MAKE) -C $(BUILDROOT) O=$(O) BR2_EXTERNAL=$(BUILDROOT_IHOST_EXTERNAL):$(BUILDROOT_EXTERNAL)

buildroot-help:
	$(MAKE) -C $(BUILDROOT) O=$(O) BR2_EXTERNAL=$(BUILDROOT_IHOST_EXTERNAL):$(BUILDROOT_EXTERNAL) help

help:
	@echo "Run 'make <target>' to build a target image."
	@echo "Run 'make <target>-config' to configure buildroot for a target."
	@echo ""
	@echo "Supported targets: $(TARGETS)"
	@echo ""
	@echo "Unknown Makefile targets fall back to Buildroot make - for details run 'make buildroot-help'"
	@echo ""
	@echo "QEMU CI lane (boots haos_qemu image, runs EMU-category suites):"
	@echo "  qemu-test            Build (if needed) + boot + test the qemu OS image"
	@echo "  qemu-test-no-build   Same, but reuse a previously-built qemu image"
	@echo "  See ga-ihost-docs/QEMU-CI.md for what's covered + how to debug failures."

# The QEMU CI lane has its own output dir (ga_output_qemu) so it never
# conflicts with the iHost build cache in ga_output. Both targets delegate
# to scripts/qemu-ci.sh which handles preflight, build, boot, and result
# parsing — see that script's --help for the full option surface.
.PHONY: qemu-test qemu-test-no-build
qemu-test:
	$(BUILDDIR)/scripts/qemu-ci.sh --build auto

qemu-test-no-build:
	$(BUILDDIR)/scripts/qemu-ci.sh --build no
