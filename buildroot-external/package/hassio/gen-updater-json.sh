#!/usr/bin/env bash
# gen-updater-json.sh <version.json> <images-dir> <channel>
#
# Prints the updater.json the data partition is seeded with (patch 0131,
# create-data-partition.sh). A fresh device has not fetched the channel yet: a
# field missing here makes the Supervisor fall back to the UPSTREAM image name
# (ghcr.io/home-assistant/<arch>-hassio-<x>), which is not baked, so without
# internet PluginBase.install() retries forever and cli never comes up (Odoo
# #2065). So the seed carries every version + image the line bakes:
#   - the five plugins cli dns audio multicast observer: MANDATORY. Missing
#     from version.json, not a GA image name, or not baked at that version
#     = build error (exit 1, message on stderr);
#   - supervisor and Core: seeded when baked (a board may skip them,
#     GA_HASSIO_SKIP_IMAGES); otherwise said so on stderr and left out.
# Image names stay templates ("{arch}") exactly as in version.json: the
# Supervisor formats them itself.
set -euo pipefail

vj=${1:?version.json missing}
img_dir=${2:?images dir missing}
channel=${3:?channel missing}

fail() { echo "gen-updater-json: ERROR: $*" >&2; exit 1; }
baked() { compgen -G "${img_dir}/*${1}@*" > /dev/null; } # <name>_<version>

out=$(jq -n --arg channel "${channel}" '{channel: $channel}')

core_version=$(jq -r '.core // empty' "${vj}")
core_image=$(jq -r '.images.core // empty' "${vj}")
if [ "${core_version}" != "landingpage" ] && [ -n "${core_version}" ] && baked "${core_version}"; then
	out=$(jq --arg v "${core_version}" --arg i "${core_image}" \
		'.homeassistant = $v | .image.homeassistant = $i' <<<"${out}")
else
	echo "gen-updater-json: no full Core baked -- Core not seeded" >&2
fi

for p in cli dns audio multicast observer; do
	v=$(jq -r --arg p "${p}" '.[$p] // empty' "${vj}")
	i=$(jq -r --arg p "${p}" '.images[$p] // empty' "${vj}")
	{ [ -n "${v}" ] && [ "${v}" != "latest" ]; } || fail "version.json: ${p} version '${v}' is not a pinned version"
	case "${i}" in ghcr.io/greenautarky/*) ;; *) fail "version.json: images.${p} '${i}' is not a greenautarky image" ;; esac
	baked "hassio-${p}_${v}" || fail "plugin ${p} ${v} is not baked in ${img_dir} (seeding it would force a pull)"
	out=$(jq --arg p "${p}" --arg v "${v}" --arg i "${i}" '.[$p] = $v | .image[$p] = $i' <<<"${out}")
done

sv=$(jq -r '.supervisor // empty' "${vj}")
si=$(jq -r '.images.supervisor // empty' "${vj}")
if [ -n "${sv}" ] && [ -n "${si}" ] && baked "hassio-supervisor_${sv}"; then
	out=$(jq --arg v "${sv}" --arg i "${si}" '.supervisor = $v | .image.supervisor = $i' <<<"${out}")
else
	echo "gen-updater-json: no Supervisor baked at '${sv}' -- Supervisor not seeded" >&2
fi

printf '%s\n' "${out}"
