#!/usr/bin/env bash
# check-core-image.sh — refuse to bake a Core image the Supervisor cannot run.
#
# Usage: check-core-image.sh <version.json> <machine> [<arch> [<channel>]]
#   <arch>    armv7 (default) or aarch64: selects the GA Core image
#             ghcr.io/greenautarky/home-assistant-<arch> and the platform the
#             config is read for.
#   <channel> stable (default) | beta | dev. A `-dev` tag suffix (the GA aarch64
#             dev Core, e.g. 2026.10.4.3-dev) is accepted ONLY when <channel> is dev.
#   Test hook: CORE_IMAGE_CONFIG_FILE=<file> reads the image config from a file
#   instead of the registry (fixtures in tests/gates/core_image/).
#
# Upstream stopped building Home Assistant Core for armv7 in late 2025. A
# current Core on this hardware is the GA armv7 build
# (ghcr.io/greenautarky/home-assistant-armv7). This checks, at configure time:
#   1. images.core names that GA image — not the frozen upstream one
#   2. the Core tag is a calver from 2026 or later (a floor, not a pin)
#   3. the image at that tag carries what the Supervisor reads:
#      io.hass.version == the tag, io.hass.arch == <arch>, io.hass.machine == <machine>, and runs
#      s6 /init. An image can boot on its own and still lack these; the
#      2026.8.2 tag first published on 2026-09-22 did.
# Expectations are pinned here, never read from the image under test.
set -euo pipefail

vj="${1:?usage: $0 <version.json> <machine>}"
machine="${2:?usage: $0 <version.json> <machine> [<arch> [<channel>]]}"
arch="${3:-armv7}"
channel="${4:-stable}"
case "$arch" in
  armv7)   WANT_PLAT=(--override-arch arm --override-variant v7) ;;
  aarch64) WANT_PLAT=(--override-arch arm64) ;;
  *) echo "ERROR: core image: unknown arch '$arch' (armv7|aarch64)"; exit 1 ;;
esac
case "$channel" in stable|beta|dev) ;; *) echo "ERROR: core image: unknown channel '$channel'"; exit 1 ;; esac
WANT_IMAGE="ghcr.io/greenautarky/home-assistant-${arch}"
WANT_ENTRYPOINT='["/init"]'
MIN_YEAR=2026

img="$(jq -r '.images.core // empty' "$vj")"
tag="$(jq -r --arg m "$machine" '.homeassistant[$m] // .core // empty' "$vj")"
core="$(jq -r '.core // empty' "$vj")"
fail=0
err() { echo "ERROR: core image: $*"; fail=1; }

[ "$img" = "$WANT_IMAGE" ] || err "version.json images.core='$img' (must be $WANT_IMAGE — upstream no longer builds Core for this arch)"
[ "$tag" = "$core" ] || err "homeassistant.$machine='$tag' differs from core='$core'"
if [[ "$tag" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(\.[0-9]+)?-dev$ ]]; then
  [ "$channel" = dev ] || err "tag '$tag' carries -dev but the channel is '$channel' (a -dev Core is for the dev channel only)"
elif [[ ! "$tag" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  err "tag '$tag' is not a calver"
elif (( ${tag%%.*} < MIN_YEAR )); then
  err "tag '$tag' is older than $MIN_YEAR"
fi
[ "$fail" -eq 0 ] || exit 1

if [ -n "${CORE_IMAGE_CONFIG_FILE:-}" ]; then
  cfg="$(cat "$CORE_IMAGE_CONFIG_FILE")"
else
  cfg="$(skopeo inspect --config "${WANT_PLAT[@]}" "docker://${img}:${tag}")" \
    || { echo "ERROR: core image: cannot read the config of ${img}:${tag}"; exit 1; }
fi
lbl() { jq -r --arg k "$1" '.config.Labels[$k] // ""' <<<"$cfg"; }
[ "$(lbl io.hass.version)" = "$tag" ]     || err "${img}:${tag} label io.hass.version='$(lbl io.hass.version)' (want '$tag')"
[ "$(lbl io.hass.arch)" = "$arch" ]       || err "${img}:${tag} label io.hass.arch='$(lbl io.hass.arch)' (want '$arch')"
[ "$(lbl io.hass.machine)" = "$machine" ] || err "${img}:${tag} label io.hass.machine='$(lbl io.hass.machine)' (want '$machine')"
ep="$(jq -c '.config.Entrypoint // null' <<<"$cfg")"
[ "$ep" = "$WANT_ENTRYPOINT" ]            || err "${img}:${tag} Entrypoint=$ep (want $WANT_ENTRYPOINT — the Supervisor supervises Core through s6)"
[ "$fail" -eq 0 ] || exit 1
echo "core image ok: ${img}:${tag} (labels + s6 entrypoint)"
