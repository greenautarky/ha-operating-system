#!/usr/bin/env bash
# probe-ga-version-url.sh — run hassio.mk's REAL install recipe into a scratch dir.
#
# Usage: scripts/probe-ga-version-url.sh <hassio.mk> <target-dir>
#
# The image carries /etc/ga-version-url (the haos-version base URL the GA
# Supervisor polls, from 2025.11.5.6). It is written by the hassio package's
# HASSIO_INSTALL_TARGET_CMDS from HASSIO_VERSION_URL. This script evaluates
# THAT recipe with GNU make — never a copy of it — against <target-dir>, so a
# check can read the file a bake would produce without running a bake.
# Consumers: scripts/check-version-url-scope.sh (lint) and
# tests/ga_tests/run_build_tests.sh (XVER-09).
#
# Exit 0 = make ran the recipe. Whether it produced a file, and what is in it,
# is the caller's question: an absent recipe runs as an empty one here.
set -uo pipefail
MK="${1:?usage: $0 <hassio.mk> <target-dir>}"
T="${2:?usage: $0 <hassio.mk> <target-dir>}"
[ -f "$MK" ] || { echo "probe-ga-version-url: hassio.mk not found: $MK" >&2; exit 2; }
command -v make >/dev/null 2>&1 || { echo "probe-ga-version-url: make not available" >&2; exit 2; }
mkdir -p "$T"
# hassio.mk has no rules of its own and calls $(generic-package), which is
# undefined outside buildroot and expands to nothing. The channel and core
# lookups are not evaluated: BR2_PACKAGE_HASSIO_FULL_CORE is unset here.
make -s --no-print-directory -f "$MK" -f - TARGET_DIR="$T" ga-version-url-probe <<'EOF'
.PHONY: ga-version-url-probe
ga-version-url-probe:
	$(HASSIO_INSTALL_TARGET_CMDS)
EOF
