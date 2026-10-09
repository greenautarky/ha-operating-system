include $(sort $(wildcard $(BR2_EXTERNAL_HASSOS_PATH)/package/*/*.mk))

# CPE identifiers for upstream Buildroot packages that ship without one.
#
# Without a CPE, Buildroot's cve-check cannot match a package against NVD at
# all, and the SBOM scan reports it as clean — it is invisible, not safe. This
# file is included AFTER every package/*/*.mk has been evaluated, so the
# <PKG>_CPE_ID_VENDOR route (read once, at eval time) is closed; setting the
# two variables show-info reads (<PKG>_CPE_ID_VALID, <PKG>_CPE_ID) is what
# reaches the SBOM. Only add a CPE verified against NVD: a wrong one looks
# covered and can never match (scan-cves.sh --package-coverage fails on that).
#
# nftables: NVD names it cpe:2.3:a:netfilter:nftables (checked 2026-10-09
# against the NVD mirror the build uses).
NFTABLES_CPE_ID_VALID = YES
NFTABLES_CPE_ID = cpe:2.3:a:netfilter:nftables:$(NFTABLES_VERSION):-:*:*:*:*:*:*

.PHONY: linux-check-dotconfig
linux-check-dotconfig: linux-check-configuration-done
	CC=$(TARGET_CC) LD=$(TARGET_LD) srctree=$(LINUX_SRCDIR) \
	ARCH=$(if $(BR2_x86_64),x86,$(if $(BR2_aarch64),arm64,$(ARCH))) \
	SRCARCH=$(if $(BR2_x86_64),x86,$(if $(BR2_aarch64),arm64,$(ARCH))) \
	 $(BR2_EXTERNAL_HASSOS_PATH)/scripts/check-dotconfig.py \
		$(BR2_CHECK_DOTCONFIG_OPTS) \
		--src-kconfig $(LINUX_SRCDIR)Kconfig \
		--actual-config $(LINUX_SRCDIR).config \
		$(shell echo $(BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE) $(BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES))
