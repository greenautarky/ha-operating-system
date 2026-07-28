################################################################################
# netbird (v0.71.4) — ARMv7 build for Buildroot with systemd service
################################################################################

# Pin the IMMUTABLE commit SHA of v0.71.4, not the mutable tag: a git checkout
# verifies the SHA against the fetched objects, so a moved/re-cut upstream tag
# cannot swap the source under us (the git SHA is itself the content hash — no
# .hash file needed for a git package). Update this SHA when bumping the version.
# SHA of refs/tags/v0.71.4 (netbirdio/netbird), resolved 2026-07-27. [Vuln-11]
# The upstream tag this SHA resolves to. Kept machine-readable so the
# ga_build.sh pre-flight and the SRC-PIN-03 test can verify SHA-vs-tag
# agreement WITHOUT network access. Bump both lines together.
NETBIRD_UPSTREAM_TAG  = v0.71.4
NETBIRD_VERSION       = 0358be23136da50e829ba99a83e54ef555071a7f
NETBIRD_SITE          = https://github.com/netbirdio/netbird.git
NETBIRD_SITE_METHOD   = git

NETBIRD_LICENSE       = BSD-3-Clause
NETBIRD_LICENSE_FILES = LICENSE

NETBIRD_GOMOD         = github.com/netbirdio/netbird
NETBIRD_DL_SUBDIR     = netbird

# ---------------- Go env (ARMv7) ----------------
NETBIRD_GO_ENV       += GOOS=linux
NETBIRD_GO_ENV       += GOARCH=arm
NETBIRD_GO_ENV       += GOARM=7
NETBIRD_GO_ENV       += CGO_ENABLED=0
NETBIRD_GO_ENV       += GOPROXY=https://proxy.golang.org,direct

# Small binary (CGO disabled => effectively static)
# Embed version so "netbird version" shows the release tag, not "development"
NETBIRD_LDFLAGS       = -s -w -X github.com/netbirdio/netbird/version.version=0.71.4

# --------------- Configure ----------------------
define NETBIRD_CONFIGURE_CMDS
	cd $(@D); $(TARGET_MAKE_ENV) $(NETBIRD_GO_ENV) $(GO_BIN) mod vendor
endef

# --------------- Build (client) -----------------
define NETBIRD_BUILD_CMDS
	mkdir -p $(@D)/bin
	cd $(@D); $(TARGET_MAKE_ENV) $(NETBIRD_GO_ENV) \
		$(GO_BIN) build -v -mod=vendor -trimpath -buildvcs=false \
		-ldflags "$(NETBIRD_LDFLAGS)" -o bin/netbird ./client
	test -x $(@D)/bin/netbird
endef

# ---------------- Install binary ----------------
define NETBIRD_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/bin/netbird $(TARGET_DIR)/usr/bin/netbird
	# optional: keep for compatibility; runtime config/logs go to /mnt/data via service
	mkdir -p $(TARGET_DIR)/var/log/netbird $(TARGET_DIR)/var/lib/netbird
endef

################################################################################
# systemd service + enable at boot
################################################################################

define NETBIRD_INSTALL_INIT_SYSTEMD
	# install service unit
	$(INSTALL) -D -m 0644 $(NETBIRD_PKGDIR)/netbird.service \
		$(TARGET_DIR)/etc/systemd/system/netbird.service
	# enable for multi-user.target
	mkdir -p $(TARGET_DIR)/etc/systemd/system/multi-user.target.wants
	ln -sf ../netbird.service \
		$(TARGET_DIR)/etc/systemd/system/multi-user.target.wants/netbird.service
endef

################################################################################

$(eval $(golang-package))
