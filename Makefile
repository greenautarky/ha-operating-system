# Thin wrapper around Buildroot for the GreenAutarky OS tree on HAOS 18.x:
#
#   haos/                 upstream Home Assistant OS, UNMODIFIED (git submodule;
#                         its own haos/buildroot submodule is Buildroot itself)
#   <board dir>           board external (buildroot-ihost/ for the iHost)
#   buildroot-external/   the GA layer, external GA_HAOS (shared by every board)
#
# Paths come from scripts/lib/tree-paths.sh, the one map of the layout. The
# release build is scripts/ga_build.sh (preflights, stamping, gates); this
# Makefile is the developer entry for the same tree.
#
#   make ihost | dsgw210        patch haos/ + configure + build
#   make ihost-config           patch haos/ + configure only
#   make haos-patch             apply the GA patch set to haos/ (fail-loud)
#   make haos-unpatch           revert it (haos/ back to upstream)
#   make <buildroot target>     anything else goes to Buildroot (O=, externals set)

REPO      := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TREE_MAP  := $(REPO)/scripts/lib/tree-paths.sh
HAOS      := $(REPO)/$(shell . $(TREE_MAP); echo $$GA_HAOS_DIR)
BUILDROOT := $(HAOS)/buildroot
GA_LAYER  := $(REPO)/$(shell . $(TREE_MAP); echo $$GA_LAYER_DIR)
BOARDS    := $(shell . $(TREE_MAP); echo $$GA_BOARDS)

# Board for non-board goals (haos-patch, linux-menuconfig, ...): BOARD=, else ihost.
BOARD ?= $(or $(firstword $(filter $(BOARDS),$(patsubst %-config,%,$(MAKECMDGOALS)))),ihost)
board_dir  = $(REPO)/$(shell . $(TREE_MAP); ga_board_var BOARD_DIR $(1))
board_defc = $(notdir $(shell . $(TREE_MAP); ga_board_var DEFCONFIG $(1)))

O ?= $(REPO)/output
override O := $(abspath $(O))

# Order matters for external.mk evaluation: HAOS, then the board, then GA.
EXTERNALS = $(HAOS)/buildroot-external:$(call board_dir,$(BOARD)):$(GA_LAYER)
BR = $(MAKE) -C $(BUILDROOT) O=$(O) BR2_EXTERNAL=$(EXTERNALS)

.NOTPARALLEL:
.PHONY: default help haos-init haos-patch haos-unpatch $(BOARDS) $(addsuffix -config,$(BOARDS))

default: help

help:
	@echo "Boards: $(BOARDS)"
	@echo "  make <board>          full build into O=$(O)"
	@echo "  make <board>-config   configure only"
	@echo "  make haos-patch | haos-unpatch"
	@echo "haos pin: $$(git -C $(REPO) ls-files -s $(notdir $(HAOS)) | awk '{print $$2}')"

haos-init:
	@if [ ! -e $(HAOS)/.git ] || [ ! -e $(BUILDROOT)/.git ]; then \
		echo "=== initialising haos/ (recursive) ==="; \
		git -C $(REPO) submodule update --init --recursive $(notdir $(HAOS)); \
	fi

haos-patch: haos-init
	$(REPO)/scripts/apply-haos-patches.sh

haos-unpatch:
	$(REPO)/scripts/apply-haos-patches.sh --revert

$(addsuffix -config,$(BOARDS)): %-config: haos-patch
	@if [ -f $(O)/.config ] && ! grep -q 'BR2_DEFCONFIG="$(call board_dir,$*)/configs/$(call board_defc,$*)"' $(O)/.config; then \
		echo "FAIL: $(O) holds a config for another defconfig; use another O= or 'make distclean'." >&2; exit 1; \
	fi
	$(if $(filter ihost,$*),$(REPO)/scripts/ihost/check-haos-patch-mirror.sh)
	$(if $(filter dsgw210,$*),$(REPO)/scripts/dsgw210/check-haos-patch-mirror.sh)
	$(MAKE) -C $(BUILDROOT) O=$(O) BR2_EXTERNAL=$(HAOS)/buildroot-external:$(call board_dir,$*):$(GA_LAYER) $(call board_defc,$*)

$(BOARDS): %: %-config
	$(MAKE) -C $(BUILDROOT) O=$(O) BR2_EXTERNAL=$(HAOS)/buildroot-external:$(call board_dir,$*):$(GA_LAYER)

# Everything else: straight to Buildroot with the same O= and externals.
.DEFAULT:
	$(BR) "$@"
