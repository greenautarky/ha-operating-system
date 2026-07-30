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

# Persist the Go module cache across builds.
#
# Without this, every build re-downloads the full module graph (~500 MB) from
# proxy.golang.org, so every build is freshly exposed to a flaky path. That is
# not hypothetical: on 2026-07-30 two consecutive full builds died here, ~45 min
# apart, with `stream error: … INTERNAL_ERROR; received from peer` — an HTTP/2
# symptom, on two DIFFERENT modules (pion/transport, then docker/docker). A
# direct retry of the same download afterwards succeeded, with and without h2,
# so nothing was broken upstream and nothing was wrong with the pin. The build
# was simply re-rolling the dice on a large transfer, every time.
#
# $(DL_DIR) is the right home for it: it is the download cache by definition,
# already persistent, and already the /cache mount on ga-builder (31 GB of
# buildroot tarballs live there). Using it needs no new mount and still works
# for a local build with no cache volume at all.
NETBIRD_GO_ENV       += GOMODCACHE=$(DL_DIR)/gomod

# Small binary (CGO disabled => effectively static)
# Embed version so "netbird version" shows the release tag, not "development"
NETBIRD_LDFLAGS       = -s -w -X github.com/netbirdio/netbird/version.version=0.71.4

# --------------- Configure ----------------------
# `go mod vendor` is the one step in this package that must reach the network.
# Retry it, because a single dropped stream should not cost a 45-minute build.
#
# The retry deliberately does NOT swallow a real outage: each attempt is logged,
# and the explicit vendor/ check after the loop fails the build loudly. Without
# that check a three-times-failed vendor would slide into NETBIRD_BUILD_CMDS and
# surface as a confusing -mod=vendor error several steps later, which is exactly
# the kind of misdirection that makes a transient fault look like a code fault.
define NETBIRD_CONFIGURE_CMDS
	cd $(@D); \
	for attempt in 1 2 3; do \
		$(TARGET_MAKE_ENV) $(NETBIRD_GO_ENV) $(GO_BIN) mod vendor && break; \
		echo "netbird: 'go mod vendor' failed (attempt $$attempt/3) — retrying in 15s"; \
		sleep 15; \
	done
	test -d $(@D)/vendor || { \
		echo "netbird: 'go mod vendor' failed 3 times — module fetch is genuinely down, not flaky"; \
		exit 1; \
	}
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
