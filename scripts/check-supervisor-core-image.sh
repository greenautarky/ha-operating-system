#!/usr/bin/env bash
# Assert that the pinned Supervisor image resolves Core from the UPSTREAM
# namespace.
#
# WHY THIS EXISTS
#
# The Supervisor decides which Home Assistant Core image to pull. Its
# `default_image` property used to return a greenautarky-prefixed name, from the
# era when Core was a GA fork. Core is stock upstream now, so that name resolves
# to nothing: a device flashed from an image whose Supervisor still returns it
# hits "No version found" and sits in a landingpage pull forever. It fails on the
# FIRST boot of a fresh flash, which is the least forgiving place to find it.
#
# The revert lives on the branch this fork publishes from. It is NOT on the
# fork's default branch, and the default branch is where tooling, dependabot and
# reflex all point. A Supervisor built from there would be correctly versioned,
# correctly namespaced, present in the registry and channel-consistent — every
# existing check would pass — and it would still brick every fresh flash.
#
# So this check does not ask where the image came from. It asks what the image
# DOES, which is the only question whose answer cannot be faked by a tag.
#
# Usage:
#   scripts/check-supervisor-core-image.sh                 # checks the pin
#   scripts/check-supervisor-core-image.sh <image-ref>     # checks one image
#
# Exit: 0 = upstream namespace (good), 1 = wrong namespace, 2 = BROKEN CHECK.
#
# Exit 2 is deliberate and separate. A check that cannot read the thing it
# judges must not report the same status as one that read it and was satisfied —
# "I could not look" and "nothing to see" are the confusion this whole test
# suite exists to prevent.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
VERSION_YAML="${REPO_ROOT}/version.yaml"
IMAGE_BASE="${SUPERVISOR_IMAGE_BASE:-ghcr.io/greenautarky/armv7-hassio-supervisor}"
PLATFORM="${SUPERVISOR_PLATFORM:-linux/arm/v7}"

# Where the Supervisor's source lands inside its own image. Both layouts have
# shipped; try each and fail loudly if neither is there, rather than treating an
# unreadable image as a clean one.
CANDIDATE_PATHS=(
  "/usr/src/supervisor/supervisor/homeassistant/module.py"
  "/usr/src/supervisor/homeassistant/module.py"
)

die_broken() { echo "BROKEN CHECK: $*" >&2; exit 2; }

resolve_ref() {
  if [ $# -ge 1 ] && [ -n "${1:-}" ]; then
    printf '%s\n' "$1"
    return
  fi
  [ -f "$VERSION_YAML" ] || die_broken "version.yaml not found at $VERSION_YAML"
  local pin
  pin="$(sed -nE 's/^[[:space:]]*homeassistant_supervisor:[[:space:]]*"?([^"[:space:]#]+)"?.*/\1/p' \
        "$VERSION_YAML" | head -1)"
  [ -n "$pin" ] || die_broken "no homeassistant_supervisor pin in version.yaml"
  printf '%s:%s\n' "$IMAGE_BASE" "$pin"
}

REF="$(resolve_ref "${1:-}")" || exit 2
echo "Supervisor image under test: ${REF}"

command -v docker >/dev/null 2>&1 || die_broken "docker is required to read the image"

docker pull -q --platform "$PLATFORM" "$REF" >/dev/null 2>&1 \
  || die_broken "cannot pull ${REF} for ${PLATFORM}"

# `create` never starts the container, so a foreign-architecture image can be
# read on any host without qemu. Running it would need emulation and would prove
# less: we want the shipped source, not a live answer.
CID="$(docker create --platform "$PLATFORM" "$REF" 2>/dev/null)" \
  || die_broken "cannot create a container from ${REF}"
# shellcheck disable=SC2064  # expand CID now, on purpose
trap "docker rm -f '${CID}' >/dev/null 2>&1 || true" EXIT

MOD=""
TMP="$(mktemp)"
for p in "${CANDIDATE_PATHS[@]}"; do
  if docker cp "${CID}:${p}" "$TMP" >/dev/null 2>&1; then MOD="$p"; break; fi
done
[ -n "$MOD" ] || die_broken "homeassistant/module.py not found at any known path in ${REF}"
echo "Read ${MOD} from the image."

# The property, not a grep for a string anywhere in the file: a comment
# mentioning the old namespace must not fail the check, and a return statement
# hiding under a docstring must not pass it.
RETURN_LINE="$(awk '/def default_image/{f=1} f && /return f"/{print; exit}' "$TMP")"
[ -n "$RETURN_LINE" ] || die_broken "default_image has no return statement in ${MOD} — the check could not judge anything"

NAMESPACE="$(printf '%s\n' "$RETURN_LINE" | sed -E 's|.*return f"([^{"]*).*|\1|')"
[ -n "$NAMESPACE" ] || die_broken "could not parse a namespace out of: ${RETURN_LINE}"

rm -f "$TMP"
echo "default_image resolves Core from: ${NAMESPACE}"

case "$NAMESPACE" in
  ghcr.io/home-assistant/*)
    echo "OK: Core comes from the upstream namespace."
    exit 0
    ;;
  *)
    echo "FAIL: this Supervisor resolves Core from '${NAMESPACE}'." >&2
    echo "      Core is stock upstream, so that name resolves to nothing and every" >&2
    echo "      fresh flash stops in a landingpage pull on first boot." >&2
    echo "      This is what a Supervisor built from the fork's default branch does." >&2
    echo "      Build it from the branch the fork publishes releases from." >&2
    exit 1
    ;;
esac
