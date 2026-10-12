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

# Fixes carried as patches for packages whose version is pinned by the buildroot
# submodule (an HA tree we do not push to).
#
# The patches live in buildroot-external/patches/<pkg>/ and apply through
# BR2_GLOBAL_PATCH_DIR, after the package's own patches. Buildroot's cve-check
# matches NVD ranges by VERSION and cannot see a backport, so each CVE a patch
# closes is declared here, exactly as the package's own .mk does for the ones
# it patches. <PKG>_IGNORE_CVES is read by show-info (lazily), so appending it
# after the package .mk was evaluated reaches the SBOM; the CVEs then show up
# there as resolved_with_pedigree instead of exploitable.
#
# libglib2 2.82.5: nine patches, 0101-0109, one per CVE. Upstream fixed these in
# 2.84.1 - 2.88.1 and main; a version bump needs a buildroot tree we can push.
#   0101 CVE-2025-13601   0102 CVE-2025-14512   0103 CVE-2026-58010
#   0104 CVE-2026-58011   0105 CVE-2026-58012   0106 CVE-2026-58013
#   0107 CVE-2026-58014   0108 CVE-2026-58015   0109 CVE-2026-58016
LIBGLIB2_IGNORE_CVES += CVE-2025-13601
LIBGLIB2_IGNORE_CVES += CVE-2025-14512
LIBGLIB2_IGNORE_CVES += CVE-2026-58010
LIBGLIB2_IGNORE_CVES += CVE-2026-58011
LIBGLIB2_IGNORE_CVES += CVE-2026-58012
LIBGLIB2_IGNORE_CVES += CVE-2026-58013
LIBGLIB2_IGNORE_CVES += CVE-2026-58014
LIBGLIB2_IGNORE_CVES += CVE-2026-58015
LIBGLIB2_IGNORE_CVES += CVE-2026-58016
# CVE-2025-4056 is in the Windows-only process spawning code (gspawn-win32.c),
# which is not compiled on Linux. Not affected, no patch.
LIBGLIB2_IGNORE_CVES += CVE-2025-4056

# xz 5.6.4: two patches, 0101-0102, the upstream v5.6 branch commits for
# GHSA-5qpq-xqfv-j9pg (fixed in 5.8.4; no CVE id assigned yet, so there is
# nothing to list here and NVD has no entry for cve-check to match).

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
