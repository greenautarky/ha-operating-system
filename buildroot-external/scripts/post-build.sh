#!/bin/bash
# GA_HAOS post-build. Listed in BR2_ROOTFS_POST_BUILD_SCRIPT AFTER upstream
# HAOS's ($(BR2_EXTERNAL_HAOS_PATH)/scripts/post-build.sh, unmodified), so
# os-release and the RAUC config already exist when this runs, and BEFORE the
# board's (which runs the board's post-build.d hooks).
#
#   $1 = TARGET_DIR, $2 = board dir (BR2_ROOTFS_POST_SCRIPT_ARGS)
#
# Until HAOS 18.x the GA lines below were edits of HAOS's own post-build.sh.
set -e

TARGET_DIR=${1:?TARGET_DIR missing}

OS_RELEASE="${TARGET_DIR}/usr/lib/os-release"
[ -f "${OS_RELEASE}" ] || { echo "ga-haos post-build: FAIL: ${OS_RELEASE} missing (the HAOS post-build must run first)" >&2; exit 1; }

# PRETTY_NAME: "<name> <version>, based on Home Assistant"
sed -i 's/^PRETTY_NAME="\(.*\)"$/PRETTY_NAME="\1, based on Home Assistant"/' "${OS_RELEASE}"

{
    # GreenAutarky build info (set by ga_build.sh via env vars)
    if [ -n "${GA_BUILD_TIMESTAMP:-}" ]; then
        # GA_ENV is a runtime label (telemetry `env`), constant since
        # ADR-0027 D9 — there is one build. D10 replaces it with fleet_env.
        echo "GA_BUILD_ID=\"$(date '+%F %T') (prod)\""
        echo "GA_BUILD_TIMESTAMP=\"${GA_BUILD_TIMESTAMP}\""
        echo "GA_ENV=\"prod\""
    fi
    # GA-side release identifier (e.g. "BOSv1.2.0") alongside the cryptic
    # HAOS-internal VERSION_ID. Operators + fleet-manager read this; nothing
    # in the supervisor cares about it. ga_build.sh resolves it (env, else
    # version.yaml gaos_release) and refuses to build without one.
    if [ -n "${GA_RELEASE:-}" ]; then
        echo "GA_RELEASE=\"${GA_RELEASE}\""
    fi
} >> "${OS_RELEASE}"

# GA-side release identifier also lives at /etc/ga-release for cheap
# `cat /etc/ga-release` use by tests, ga_manager, telegraf tags, etc.
if [ -n "${GA_RELEASE:-}" ]; then
    printf '%s\n' "${GA_RELEASE}" > "${TARGET_DIR}/etc/ga-release"
    chmod 0644 "${TARGET_DIR}/etc/ga-release"
fi

# The GA layer's build-input hooks (SSH certificate plane, NetBird setup key),
# from this directory's post-build.d/: every board gets them. The board's own
# post-build.sh runs afterwards and adds its board-specific ones. A hook that
# is not executable fails the build: skipping it would ship an image without
# what the hook installs, and nothing else would notice. A directory without
# a single hook fails too, so a layout change cannot make this loop inspect
# nothing and pass.
hook_dir="$(cd "$(dirname "$0")" && pwd)/post-build.d"
shopt -s nullglob
hooks=("${hook_dir}"/*.sh)
[ "${#hooks[@]}" -gt 0 ] || { echo "ga-haos post-build: FAIL: no hooks in ${hook_dir}" >&2; exit 1; }
for s in "${hooks[@]}"; do
    [ -x "$s" ] || { echo "ga-haos post-build: FAIL: $s is not executable" >&2; exit 1; }
    echo "ga-haos post-build: running $(basename "$s")"
    "$s" "${TARGET_DIR}"
done
