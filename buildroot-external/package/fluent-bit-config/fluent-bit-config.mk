################################################################################
# Fluent Bit config + systemd wrapper
################################################################################

FLUENT_BIT_CONFIG_DEPENDENCIES = fluent-bit

################################################################################
# Minimal fluent-bit build: compile in ONLY the plugins the shipped configs use
################################################################################
#
# buildroot's fluent-bit builds every plugin (about 100 inputs, filters and
# outputs, including the Forward output, Kafka, S3 and the HTTP servers). The
# shipped configs use eight. An upstream advisory against the Forward output
# (GHSA-jrp8-r9hx-gf73 / CVE-2026-61674, all releases since 0.11.0) has no
# patched version, so the fix is to not build that code at all.
#
# FLB_MINIMAL=On flips the default of every plugin switch to Off; the explicit
# -D<switch>=On after it re-enable the ones below. Appended here, after
# buildroot's own fluent-bit.mk: FLUENT_BIT_CONF_OPTS is read when the configure
# step runs, not when the package is evaluated.
#
# THE LIST BELOW IS DERIVED FROM THE CONFIGS, NOT THE OTHER WAY ROUND. A plugin
# a config names but this list lacks makes fluent-bit refuse the WHOLE config
# ("invalid plugin") and the unit crash-loops: no logs at all, which looks like
# a quiet device. tests/gates/fluent_bit_plugins/selftest.sh reads this variable
# and every config the image ships (tier-1, debug, tier-0 OS entry point, and
# ga-telemetry-config at its version.yaml pin) and fails on any plugin that is
# named but not built, and on the Forward output being built at all.
#
#   in_systemd, in_tail, in_kmsg, in_exec   the log sources
#   in_storage_backlog                      replays the filesystem buffer that
#                                           storage.path / storage.type
#                                           filesystem write (store-and-forward)
#   filter_grep, filter_record_modifier,
#   filter_modify                           the tier stamps and priority filters
#   out_loki                                the only output
FLUENT_BIT_GA_PLUGINS = \
	FLB_IN_SYSTEMD FLB_IN_TAIL FLB_IN_KMSG FLB_IN_EXEC FLB_IN_STORAGE_BACKLOG \
	FLB_FILTER_GREP FLB_FILTER_RECORD_MODIFIER FLB_FILTER_MODIFY \
	FLB_OUT_LOKI

FLUENT_BIT_CONF_OPTS += -DFLB_MINIMAL=On \
	$(addsuffix =On,$(addprefix -D,$(FLUENT_BIT_GA_PLUGINS)))

# libfluent-bit.so (library mode, 3.6 MB on the rootfs): nothing links it, only
# the fluent-bit binary is used.
FLUENT_BIT_CONF_OPTS += -DFLB_SHARED_LIB=Off

define FLUENT_BIT_CONFIG_INSTALL_TARGET_CMDS
	# Build guard: the fluent-bit binary installed by the fluent-bit package has
	# every plugin in FLUENT_BIT_GA_PLUGINS and no Forward plugin. Runs here and
	# not as a hook of the fluent-bit package: an `update` bake dircleans this
	# package every time but not fluent-bit, so a hook there would be skipped.
	$(BR2_EXTERNAL_GA_HAOS_PATH)/../scripts/fluent-bit-plugin-guard.sh \
		--binary $(TARGET_DIR)/usr/bin/fluent-bit \
		--mk $(FLUENT_BIT_CONFIG_PKGDIR)/fluent-bit-config.mk

	# Install config directory
	mkdir -p $(TARGET_DIR)/etc/fluent-bit

	# Copy main config + parsers from this package
	$(INSTALL) -D -m 0644 $(FLUENT_BIT_CONFIG_PKGDIR)/fluent-bit.conf \
		$(TARGET_DIR)/etc/fluent-bit/fluent-bit.conf
	$(INSTALL) -D -m 0644 $(FLUENT_BIT_CONFIG_PKGDIR)/parsers.conf \
		$(TARGET_DIR)/etc/fluent-bit/parsers.conf
	$(INSTALL) -D -m 0644 $(FLUENT_BIT_CONFIG_PKGDIR)/fluent-bit-debug.conf \
		$(TARGET_DIR)/etc/fluent-bit/fluent-bit-debug.conf

	# Phase 7 scaffold — LTE network-details pipeline. Shipped to the
	# rootfs but NOT included from fluent-bit.conf yet (= no
	# `@INCLUDE network-details.conf` line in the main config). Activate
	# by uncommenting that include + populating LTE_DETAILS_TOKEN env.
	$(INSTALL) -D -m 0644 $(FLUENT_BIT_CONFIG_PKGDIR)/network-details.conf \
		$(TARGET_DIR)/etc/fluent-bit/network-details.conf

	# Env-file builder shared by BOTH tiers (fluent-bit.service here and
	# fluent-bit-tier0.service from the buildroot-ihost overlay). Kept out of
	# the unit files because systemd expands ${VAR} in Exec* lines itself.
	$(INSTALL) -D -m 0755 $(FLUENT_BIT_CONFIG_PKGDIR)/ga-fluent-bit-env \
		$(TARGET_DIR)/usr/libexec/ga-fluent-bit-env

	# Install systemd service (overrides upstream fluent-bit.service with GA version)
	$(INSTALL) -D -m 0644 $(FLUENT_BIT_CONFIG_PKGDIR)/fluent-bit.service \
		$(TARGET_DIR)/usr/lib/systemd/system/fluent-bit.service

	# Enable at boot
	mkdir -p $(TARGET_DIR)/etc/systemd/system/multi-user.target.wants
	ln -sf /usr/lib/systemd/system/fluent-bit.service \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/fluent-bit.service
endef

$(eval $(generic-package))
