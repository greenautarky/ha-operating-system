################################################################################
# Telegraf 1.30.0 - Buildroot (Go) + systemd + writable runtime config
################################################################################

TELEGRAF_VERSION = 1.30.0
TELEGRAF_SITE = https://github.com/influxdata/telegraf/archive/refs/tags
TELEGRAF_SOURCE = v$(TELEGRAF_VERSION).tar.gz

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
