# Go module floors for the Go binaries in the rootfs (GA carry).
#
# WHY: golang.org/x/{net,crypto,text,mod} are VENDORED into every Go package
# at download time from the version the upstream go.mod resolved to, so the
# patched Go toolchain (go-floor.mk) does not touch them. BOSv1.5.1-rc2 shipped
#   x/net 0.55.0 (containerd, ctr, shim) / 0.58.0 (netbird) / 0.59.0 (docker,
#   dockerd), x/crypto 0.48.0 (telegraf), x/text 0.14.0 - 0.38.0, x/mod 0.36.0.
# Advisories (https://pkg.go.dev/vuln/<id>), fixed in x/net 0.60.0 (GO-2026-6612
# Critical, GO-2026-6603, GO-2026-6611, GO-2026-6610, GO-2026-6617,
# GO-2026-5942, GO-2026-5026), x/crypto 0.52.0 / 0.56.0 (GHSA-rm3j-f69w-wqmq
# Critical, GO-2026-6354, GO-2026-6355), x/text 0.39.0 (GO-2026-5970), x/mod
# 0.40.0, floor 0.41.0 (GO-2026-6179, GO-2026-6180).
#
# HOW: scripts/go-modbump.sh runs as a POST_PATCH hook of every Go package
# below. For each module here that the package's module graph contains at a
# LOWER version, it does `go get module@floor` and re-vendors. A module the
# package does not use is left alone (never added); a higher version is kept.
# The floors are one mutually consistent set (x/net 0.60.0 requires x/crypto
# 0.57.0 and x/text 0.42.0 itself): `go get` refuses a lower crypto/text next
# to net 0.60.0, so they cannot be lowered one by one.
# go-modfloor.sum pins the content hash of each floor release; Go checks every
# download against it (and against sum.golang.org), so a swapped module fails.
#
# THE GATE: scripts/lib/go-toolchain.sh (ga_go_modfloor_verdict, GOTC-05) reads
# THIS file and fails the build tests when any Go binary in the target embeds a
# listed module below its floor. Same definition for the bump and the check.
# Format of the lines below is parsed by that gate: one `module@version` per line.
GA_GO_MODFLOOR += golang.org/x/net@v0.60.0
GA_GO_MODFLOOR += golang.org/x/crypto@v0.57.0
GA_GO_MODFLOOR += golang.org/x/text@v0.42.0
GA_GO_MODFLOOR += golang.org/x/mod@v0.41.0

# Packages that vendor those modules. -modfile is the module file the package
# builds with (docker-cli keeps vendor.mod, not go.mod).
GA_GO_MODBUMP_SCRIPT = $(BR2_EXTERNAL_HASSOS_PATH)/../scripts/go-modbump.sh
GA_GO_MODBUMP_FLOORS = $(BR2_EXTERNAL_HASSOS_PATH)/go-modfloor.mk
GA_GO_MODBUMP_SUMS   = $(BR2_EXTERNAL_HASSOS_PATH)/go-modfloor.sum

define GA_GO_MODBUMP_RUN
	$(TARGET_MAKE_ENV) $(HOST_GO_COMMON_ENV) GOMODCACHE=$(DL_DIR)/gomod \
		GOPROXY=https://proxy.golang.org,direct \
		$(GA_GO_MODBUMP_SCRIPT) $(GO_BIN) $(@D) $(GA_GO_MODBUMP_FLOORS) $(GA_GO_MODBUMP_SUMS) $(1)
endef

define NETBIRD_GA_MODBUMP
	$(call GA_GO_MODBUMP_RUN)
endef
define TELEGRAF_GA_MODBUMP
	$(call GA_GO_MODBUMP_RUN)
endef
define OS_AGENT_GA_MODBUMP
	$(call GA_GO_MODBUMP_RUN)
endef
define CONTAINERD_GA_MODBUMP
	$(call GA_GO_MODBUMP_RUN)
endef
define DOCKER_ENGINE_GA_MODBUMP
	$(call GA_GO_MODBUMP_RUN)
endef
define RUNC_GA_MODBUMP
	$(call GA_GO_MODBUMP_RUN)
endef
define DOCKER_CLI_GA_MODBUMP
	$(call GA_GO_MODBUMP_RUN,vendor.mod)
endef

NETBIRD_POST_PATCH_HOOKS       += NETBIRD_GA_MODBUMP
TELEGRAF_POST_PATCH_HOOKS      += TELEGRAF_GA_MODBUMP
OS_AGENT_POST_PATCH_HOOKS      += OS_AGENT_GA_MODBUMP
CONTAINERD_POST_PATCH_HOOKS    += CONTAINERD_GA_MODBUMP
DOCKER_ENGINE_POST_PATCH_HOOKS += DOCKER_ENGINE_GA_MODBUMP
DOCKER_CLI_POST_PATCH_HOOKS    += DOCKER_CLI_GA_MODBUMP
RUNC_POST_PATCH_HOOKS          += RUNC_GA_MODBUMP
