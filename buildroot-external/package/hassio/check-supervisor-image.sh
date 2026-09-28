#!/usr/bin/env bash
# check-supervisor-image.sh — refuse to bake a Supervisor that is not the GA one
# at the pinned version.
#
# Usage: check-supervisor-image.sh <version.json> <arch> <pin>
#   <pin> is version.yaml `homeassistant_supervisor`, passed in by hassio.mk.
#   Test hook: SUPERVISOR_IMAGE_CONFIG_FILE=<file> reads the image config from
#   a file instead of the registry (fixtures in tests/gates/supervisor_image/).
#
# The Core counterpart is check-core-image.sh. Before this, the bake compared
# only the channel's `supervisor` string with the pin and grepped the image
# template for "greenautarky" — nothing looked at the image actually fetched.
# This checks, at configure time:
#   1. images.supervisor, templated with <arch>, is exactly the GA image
#   2. the tag the bake fetches (version.json `supervisor`) == <pin>
#   3. the image at that tag says what the Supervisor itself reports:
#      io.hass.version == <pin>, io.hass.type == supervisor, io.hass.arch == <arch>
# Expectations are pinned here or passed from version.yaml, never read from
# the image under test.
set -euo pipefail

vj="${1:?usage: $0 <version.json> <arch> <pin>}"
arch="${2:?usage: $0 <version.json> <arch> <pin>}"
pin="${3:-}"
WANT_IMAGE="ghcr.io/greenautarky/${arch}-hassio-supervisor"

fail=0
err() { echo "ERROR: supervisor image: $*"; fail=1; }

[ -n "$pin" ] || { err "no version.yaml homeassistant_supervisor pin given — refusing to check against nothing"; exit 1; }
img="$(jq -r --arg a "$arch" '.images.supervisor // "" | sub("\\{arch\\}"; $a)' "$vj")"
tag="$(jq -r '.supervisor // empty' "$vj")"

[ "$img" = "$WANT_IMAGE" ] || err "version.json images.supervisor='$img' (must be $WANT_IMAGE)"
[ "$tag" = "$pin" ]        || err "version.json supervisor='$tag' but version.yaml pins '$pin'"
[ "$fail" -eq 0 ] || exit 1

if [ -n "${SUPERVISOR_IMAGE_CONFIG_FILE:-}" ]; then
  cfg="$(cat "$SUPERVISOR_IMAGE_CONFIG_FILE")"
else
  case "$arch" in
    armv7)   plat=(--override-arch arm --override-variant v7) ;;
    aarch64) plat=(--override-arch arm64) ;;
    *)       plat=(--override-arch "$arch") ;;
  esac
  cfg="$(skopeo inspect --config "${plat[@]}" "docker://${img}:${tag}")" \
    || { echo "ERROR: supervisor image: cannot read the config of ${img}:${tag}"; exit 1; }
fi
lbl() { jq -r --arg k "$1" '.config.Labels[$k] // ""' <<<"$cfg"; }
[ "$(lbl io.hass.version)" = "$pin" ]    || err "${img}:${tag} label io.hass.version='$(lbl io.hass.version)' (want '$pin')"
[ "$(lbl io.hass.type)" = "supervisor" ] || err "${img}:${tag} label io.hass.type='$(lbl io.hass.type)' (want 'supervisor')"
[ "$(lbl io.hass.arch)" = "$arch" ]      || err "${img}:${tag} label io.hass.arch='$(lbl io.hass.arch)' (want '$arch')"
[ "$fail" -eq 0 ] || exit 1
echo "supervisor image ok: ${img}:${tag} (labels match the pin)"
