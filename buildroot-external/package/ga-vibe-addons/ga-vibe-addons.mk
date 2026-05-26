################################################################################
#
# ga-vibe-addons — vendored snapshot of greenautarky/vibe_addons
#
# Cloned fresh from the public addon repo at build time WITH .git, vendored
# into /usr/share/ga/vibe_addons/ in the rootfs. ga-bootstrap copies this
# to the writable data partition on first boot and `ha store add`s it as
# a file:// URL. See the package Config.in for the rationale.
#
# To bump the snapshot for a new release, pin GA_VIBE_ADDONS_REPO_REF to
# the release tag/sha of `vibe_addons` that matches the OS bundle's
# addon-images.json versions, then rebuild (a `check-images.sh` assertion
# will eventually enforce the lockstep).
#
################################################################################

GA_VIBE_ADDONS_VERSION = 1.0
GA_VIBE_ADDONS_LICENSE = Apache-2.0
GA_VIBE_ADDONS_REDISTRIBUTE = NO

# No upstream tarball — we do a fresh `git clone` in BUILD_CMDS so the
# resulting tree carries `.git` (required for the file:// store-add to
# look like a real git repo to the Supervisor's git client).
GA_VIBE_ADDONS_SOURCE =
GA_VIBE_ADDONS_DEPENDENCIES = host-git

GA_VIBE_ADDONS_REPO_URL = https://github.com/greenautarky/vibe_addons.git
GA_VIBE_ADDONS_REPO_REF = main

define GA_VIBE_ADDONS_EXTRACT_CMDS
	# nothing to extract — see BUILD_CMDS
	true
endef

define GA_VIBE_ADDONS_BUILD_CMDS
	rm -rf $(@D)/vibe_addons
	git clone --depth=1 --branch $(GA_VIBE_ADDONS_REPO_REF) \
		$(GA_VIBE_ADDONS_REPO_URL) $(@D)/vibe_addons
	# Ensure origin is the canonical public URL — `ga_manager` will later
	# do `git fetch origin` inside the writable copy on the data partition
	# to pull newer addon versions.
	cd $(@D)/vibe_addons && \
		git remote set-url origin $(GA_VIBE_ADDONS_REPO_URL)
endef

define GA_VIBE_ADDONS_INSTALL_TARGET_CMDS
	rm -rf $(TARGET_DIR)/usr/share/ga/vibe_addons
	mkdir -p $(TARGET_DIR)/usr/share/ga
	cp -a $(@D)/vibe_addons $(TARGET_DIR)/usr/share/ga/vibe_addons
endef

$(eval $(generic-package))
