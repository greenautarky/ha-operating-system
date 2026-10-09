################################################################################
# Telegraf 1.38.0 - Buildroot (Go) + systemd + writable runtime config
################################################################################
#
# DO NOT bump to >= 1.38.4 until buildroot's Go toolchain is >= 1.26.0.
# telegraf 1.38.4 / 1.39.x set `go 1.26.0` in go.mod; the buildroot host Go is
# 1.25.7 with GOTOOLCHAIN=local (no auto-download), so the go-mod vendor stage
# fails at .stamp_downloaded ("requires go >= 1.26.0"). 1.38.0–1.38.2 keep
# `go 1.25.7` and build. The native disk store-and-forward buffer
# (buffer_strategy = "disk_write_through") we rely on is available since 1.35,
# so staying on 1.38.0 loses nothing for the edge-buffered-telemetry work.

TELEGRAF_VERSION = 1.38.0
TELEGRAF_SITE = https://github.com/influxdata/telegraf/archive/refs/tags
TELEGRAF_SOURCE = v$(TELEGRAF_VERSION).tar.gz
# telegraf.hash pins the sha256 of this GitHub archive so a moved/re-cut tag
# fails the build instead of silently swapping the source. When bumping the
# version, recompute the hash (see telegraf.hash header). [Vuln-11]

TELEGRAF_LICENSE = MIT
TELEGRAF_LICENSE_FILES = LICENSE

# Go module path for golang-package infra
TELEGRAF_GOMOD = github.com/influxdata/telegraf

# Build the telegraf CLI
TELEGRAF_BUILD_TARGETS = ./cmd/telegraf

# Optional but useful
TELEGRAF_GO_ENV += GOPROXY=https://proxy.golang.org,direct

################################################################################
# Slim build: compile in ONLY the plugins the shipped configs use
################################################################################
#
# telegraf's own custom-build mechanism: Go build tag `custom` plus one tag per
# plugin (upstream docs/CUSTOMIZATION.md; every file in plugins/*/all/ carries
# `//go:build !custom || <kind> || <kind>.<name>`). The full build is ~268 MB
# stripped on armv7; this set is ~22 MB.
#
# The list = every [[inputs|outputs|...]] table and every data_format in the
# configs this package installs (telegraf.conf, telegraf-debug.conf).
# A config naming a plugin the binary lacks makes telegraf refuse the WHOLE
# file (no metrics at all), so two checks hold this list against the configs:
#   - at PR time, scripts/telegraf-config-guard-ci.sh compares the configs'
#     plugin set with this list (no binary needed);
#   - at build time, TELEGRAF_GA_PLUGIN_GUARD below checks the shipped configs
#     against the binary just built.
# A config read at runtime from /mnt/data/telegraf/override.conf is outside
# both.
TELEGRAF_GA_PLUGINS = \
	inputs.cpu \
	inputs.disk \
	inputs.docker \
	inputs.exec \
	inputs.file \
	inputs.mem \
	inputs.net \
	inputs.ping \
	inputs.processes \
	inputs.swap \
	inputs.system \
	inputs.temp \
	inputs.wireless \
	outputs.influxdb \
	parsers.influx

TELEGRAF_TAGS += custom $(TELEGRAF_GA_PLUGINS)

################################################################################
# Install binary + default config
################################################################################

define TELEGRAF_INSTALL_TARGET_CMDS
	# Install Telegraf binary
	$(INSTALL) -D -m 0755 $(@D)/bin/telegraf \
		$(TARGET_DIR)/usr/bin/telegraf

	# Install default config into read-only rootfs
	# (runtime will copy to /mnt/data/telegraf/telegraf.conf via ExecStartPre)
	mkdir -p $(TARGET_DIR)/etc/telegraf
	if [ -f $(TELEGRAF_PKGDIR)/telegraf.conf ]; then \
	    $(INSTALL) -D -m 0644 $(TELEGRAF_PKGDIR)/telegraf.conf \
	        $(TARGET_DIR)/etc/telegraf/telegraf.conf; \
	fi
	if [ -f $(TELEGRAF_PKGDIR)/telegraf-debug.conf ]; then \
	    $(INSTALL) -D -m 0644 $(TELEGRAF_PKGDIR)/telegraf-debug.conf \
	        $(TARGET_DIR)/etc/telegraf/telegraf-debug.conf; \
	fi

	# Optional: standard dirs if you ever need them
	mkdir -p \
		$(TARGET_DIR)/etc/telegraf/telegraf.d \
		$(TARGET_DIR)/var/log/telegraf \
		$(TARGET_DIR)/var/lib/telegraf
endef

################################################################################
# systemd service + enable at boot
################################################################################

define TELEGRAF_INSTALL_INIT_SYSTEMD
	# Env-file builder — a real script, NOT inline shell in the unit:
	# systemd expands plain $${VAR} in Exec* lines itself (see ga-telegraf-env).
	$(INSTALL) -D -m 0755 $(TELEGRAF_PKGDIR)/ga-telegraf-env \
		$(TARGET_DIR)/usr/libexec/ga-telegraf-env

	# Install systemd service unit
	$(INSTALL) -D -m 0644 $(TELEGRAF_PKGDIR)/telegraf.service \
		$(TARGET_DIR)/etc/systemd/system/telegraf.service

	# Enable service for multi-user.target
	mkdir -p $(TARGET_DIR)/etc/systemd/system/multi-user.target.wants
	ln -sf ../telegraf.service \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/telegraf.service
endef

################################################################################
# Build guard: every plugin the shipped configs name must be in the binary
################################################################################
#
# Runs after install (configs + binary are the artefacts that ship). Self-tests
# the guard on guard-fixtures/ first (each must-fail fixture must report its
# SPECIFIC finding, each must-pass fixture must pass), then checks
# $(TARGET_DIR)/etc/telegraf/*.conf against $(TARGET_DIR)/usr/bin/telegraf.
# The static half (plugin package compiled into the binary) runs on any build
# host. The exec half (`telegraf plugins` / `telegraf config check`) needs
# qemu-user for the target arch on the build host; without it, it is skipped
# with a WARNING and the static half still fails the build on a missing plugin.
TELEGRAF_GA_QEMU_ARCH = $(if $(BR2_aarch64),aarch64,$(if $(BR2_arm),arm))

define TELEGRAF_GA_PLUGIN_GUARD
	$(BR2_EXTERNAL_HASSOS_PATH)/../scripts/telegraf-plugin-guard-build.sh \
		$(TARGET_DIR) $(@D) $(STAGING_DIR) $(TELEGRAF_GA_QEMU_ARCH)
endef
TELEGRAF_POST_INSTALL_TARGET_HOOKS += TELEGRAF_GA_PLUGIN_GUARD

################################################################################

$(eval $(golang-package))
