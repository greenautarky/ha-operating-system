#!/usr/bin/env bash
# =============================================================================
# check-baked-image-platforms.sh -- every baked image declares the board's platform.
# =============================================================================
# WHY: BOSv1.6.0-rc4 baked the Core image config as linux/arm with NO variant.
# The Supervisor's check_image expects linux/arm/v7 and removed and re-pulled
# the baked Core on first boot. Nothing in the build compared the config the
# bake WROTE with the platform the board needs (the registry had it right; an
# old skopeo in the download path dropped it). Cause and fix: patches/haos/0004.
#
# WHAT: for EVERY archive in --images-dir (Core, Supervisor, plug-ins, add-ons;
# OCI archive or docker-archive), read the image config the data partition is
# loaded from and compare os/architecture/variant with a constant pinned HERE
# per board arch -- never with anything derived from the archive itself:
#   armv7    linux / arm   / v7          (exact)
#   aarch64  linux / arm64 / v8 or none  (registries publish both)
# FAIL CLOSED: no archive, an unreadable archive, or a config that cannot be
# found is a failure, never a pass.
#
#   check-baked-image-platforms.sh --images-dir DIR --arch armv7|aarch64
# Prints one line per archive and "baked image platforms: N archive(s), M bad".
set -uo pipefail
IMAGES_DIR=""; ARCH=""
while [ $# -gt 0 ]; do
	case "$1" in
		--images-dir) IMAGES_DIR="${2:-}"; shift 2 ;;
		--arch) ARCH="${2:-}"; shift 2 ;;
		*) echo "usage: $0 --images-dir DIR --arch armv7|aarch64" >&2; exit 2 ;;
	esac
done
case "$ARCH" in
	armv7)   WANT_ARCH=arm;   WANT_VARIANTS=("v7") ;;
	aarch64) WANT_ARCH=arm64; WANT_VARIANTS=("" "v8") ;;
	*) echo "check-baked-image-platforms: --arch must be armv7 or aarch64 (got '${ARCH}')" >&2; exit 2 ;;
esac
[ -d "$IMAGES_DIR" ] || { echo "check-baked-image-platforms: FAIL: no images dir '${IMAGES_DIR}'" >&2; exit 1; }
for t in jq tar; do command -v "$t" >/dev/null 2>&1 || { echo "check-baked-image-platforms: FAIL: $t missing" >&2; exit 1; }; done

# config_of TAR -> the image config JSON on stdout, rc!=0 if it cannot be found
config_of() {
	local f=$1 m c
	if tar -tf "$f" index.json >/dev/null 2>&1; then          # OCI archive
		m=$(tar -xOf "$f" index.json | jq -er '.manifests[0].digest') || return 1
		c=$(tar -xOf "$f" "blobs/sha256/${m#sha256:}" | jq -er '.config.digest') || return 1
		tar -xOf "$f" "blobs/sha256/${c#sha256:}"
	elif tar -tf "$f" manifest.json >/dev/null 2>&1; then     # docker-archive
		c=$(tar -xOf "$f" manifest.json | jq -er '.[0].Config') || return 1
		tar -xOf "$f" "$c"
	else
		return 1
	fi
}

n=0; bad=0
shopt -s nullglob
for f in "$IMAGES_DIR"/*.tar; do
	n=$((n + 1)); b=$(basename "$f")
	cfg=$(config_of "$f") || { echo "  BAD   ${b}: no readable image config"; bad=$((bad + 1)); continue; }
	got=$(printf '%s' "$cfg" | jq -r '[.os // "", .architecture // "", .variant // ""] | join("/")') \
		|| { echo "  BAD   ${b}: image config is not JSON"; bad=$((bad + 1)); continue; }
	ok=0
	for v in "${WANT_VARIANTS[@]}"; do [ "$got" = "linux/${WANT_ARCH}/${v}" ] && ok=1; done
	if [ "$ok" = 1 ]; then echo "  ok    ${b%%@*}: ${got%/}"
	else echo "  BAD   ${b%%@*}: declares '${got}', ${ARCH} needs linux/${WANT_ARCH}/${WANT_VARIANTS[*]// /|}"; bad=$((bad + 1)); fi
done
echo "baked image platforms: ${n} archive(s), ${bad} bad"
[ "$n" -gt 0 ] || { echo "check-baked-image-platforms: FAIL: no archive in ${IMAGES_DIR} -- a check over zero images proves nothing" >&2; exit 1; }
[ "$bad" -eq 0 ]
