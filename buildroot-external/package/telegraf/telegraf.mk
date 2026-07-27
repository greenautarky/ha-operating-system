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

$(eval $(golang-package))
