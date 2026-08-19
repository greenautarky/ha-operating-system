#!/usr/bin/env bash
# =============================================================================
# check-baked-addon-images.sh — every pinned add-on is IN the image, or fail.
# =============================================================================
# WHY THIS EXISTS
# ---------------
# The point of pinning an add-on in addon-images.json is that its container is
# baked into the data partition, so a device installs it without reaching a
# registry. VER-10 in the build suite was supposed to prove that. It matched the
# tar by globbing the pin's SLUG:
#
#     ls "$IMAGES_DIR"/*"$addon_name"*.tar
#
# and when that found nothing it counted a SKIP and the suite still printed
# "All N addon digests match GHCR (1 skipped)". Two ways that goes wrong, both
# measured against the 2026-08-18 bake's real filenames:
#
#   * `sonoff_dongle_flasher` has never been checked. The pin key uses
#     underscores, the tar is `…sonoff-dongle-flasher-armv7…` with dashes, so
#     neither the glob nor its `grep -i` fallback can ever match it.
#   * A pin whose image was never fetched skips too — which is precisely the
#     failure this check exists to catch. Pinning ga_hmvapp_addon and having the
#     fetch quietly not produce it would have read as green.
#
# So the tar is no longer guessed from the slug. It is DERIVED from the pinned
# image reference, which is what fetch-addon-images.sh names the file after:
#
#     ghcr.io/greenautarky/ga_manager-{arch}  +  0.116.0
#     -> ghcr.io_greenautarky_ga_manager-armv7_0.116.0@sha256_<digest>.tar
#
# Exact prefix, one match required. Verified against all 14 tars of the
# 2026-08-18 bake before this was written, including the sonoff one.
#
# WHAT IS FATAL AND WHAT IS MERELY UNVERIFIED
# -------------------------------------------
# Presence is local and unconditional: a pinned add-on with no tar is a FAIL,
# never a skip. Whether the baked digest still matches GHCR needs the network
# and credentials, so an unreadable registry is reported as UNVERIFIED, counted,
# and named — it must not silently reduce coverage, but it must also not turn a
# registry outage into a red bake. The two are different claims and are counted
# separately.
#
# Zero pins is a failure, not a pass: a check that inspected nothing has proven
# nothing.
set -uo pipefail

IMAGES_DIR=""
PINS=""
ARCH="armv7"
CHECK_REGISTRY=1

while [ $# -gt 0 ]; do
    case "$1" in
        --images-dir) IMAGES_DIR="$2"; shift 2 ;;
        --pins)       PINS="$2"; shift 2 ;;
        --arch)       ARCH="$2"; shift 2 ;;
        --no-registry) CHECK_REGISTRY=0; shift ;;
        -h|--help)
            echo "usage: $0 --images-dir DIR --pins addon-images.json [--arch armv7] [--no-registry]"
            exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$IMAGES_DIR" ] || { echo "FATAL: --images-dir is required" >&2; exit 2; }
[ -n "$PINS" ]       || { echo "FATAL: --pins is required" >&2; exit 2; }
[ -d "$IMAGES_DIR" ] || { echo "FATAL: images dir does not exist: $IMAGES_DIR" >&2; exit 1; }
[ -f "$PINS" ]       || { echo "FATAL: pin file does not exist: $PINS" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required" >&2; exit 2; }

# skopeo's arch flags are not the add-on arch string. Only the mapping we
# actually build for is spelled out; anything else is passed through and, if
# skopeo disagrees, lands in the UNVERIFIED bucket rather than a false FAIL.
skopeo_arch_args() {
    case "$1" in
        armv7)   printf -- '--override-arch arm --override-variant v7' ;;
        aarch64) printf -- '--override-arch arm64' ;;
        amd64)   printf -- '--override-arch amd64' ;;
        *)       printf -- '--override-arch %s' "$1" ;;
    esac
}

pins="$(jq -r '.addons | keys[]' "$PINS" 2>/dev/null || true)"
pin_count="$(printf '%s\n' "$pins" | grep -c . || true)"

if [ "${pin_count:-0}" -eq 0 ]; then
    echo "FAIL: no add-on pins found in $PINS — a check that inspected nothing is not a pass"
    exit 1
fi

checked=0
verified=0
unverified=0
failed=0
unverified_names=""

for addon in $pins; do
    image="$(jq -r --arg n "$addon" '.addons[$n].image' "$PINS")"
    version="$(jq -r --arg n "$addon" '.addons[$n].version' "$PINS")"

    if [ -z "$image" ] || [ "$image" = "null" ] || [ -z "$version" ] || [ "$version" = "null" ]; then
        echo "FAIL: $addon — pin is missing image or version"
        failed=$((failed + 1))
        continue
    fi

    ref="${image//\{arch\}/$ARCH}:${version}"
    # fetch-addon-images.sh names the tar after the reference: '/' and ':' become
    # '_', then '@sha256_<digest>.tar'.
    prefix="${ref//\//_}"
    prefix="${prefix//:/_}"

    # No glob expansion into an unquoted list — a filename with a space would
    # split. find gives one path per line and an empty result when there is none.
    matches="$(find "$IMAGES_DIR" -maxdepth 1 -type f \
                    -name "${prefix}@sha256_*.tar" 2>/dev/null | sort)"
    match_count="$(printf '%s\n' "$matches" | grep -c . || true)"

    if [ "${match_count:-0}" -eq 0 ]; then
        echo "FAIL: $addon $version is pinned but NOT baked — no ${prefix}@sha256_*.tar in $IMAGES_DIR"
        echo "      A device would have to reach the registry for it, which is the"
        echo "      thing the pin exists to avoid."
        failed=$((failed + 1))
        continue
    fi
    if [ "${match_count:-0}" -gt 1 ]; then
        echo "FAIL: $addon $version matches ${match_count} tars — ambiguous, cannot say which was baked:"
        printf '%s\n' "$matches" | sed 's|^.*/|        |'
        failed=$((failed + 1))
        continue
    fi

    checked=$((checked + 1))
    tar_name="$(basename "$matches")"
    baked_digest="${tar_name##*@sha256_}"
    baked_digest="${baked_digest%.tar}"

    if ! printf '%s' "$baked_digest" | grep -qE '^[a-f0-9]{64}$'; then
        echo "FAIL: $addon — cannot read a digest out of $tar_name"
        failed=$((failed + 1))
        continue
    fi

    if [ "$CHECK_REGISTRY" -eq 0 ] || ! command -v skopeo >/dev/null 2>&1; then
        unverified=$((unverified + 1))
        unverified_names="${unverified_names} ${addon}"
        continue
    fi

    # shellcheck disable=SC2046  # the arch args are deliberately word-split
    ghcr_digest="$(skopeo inspect $(skopeo_arch_args "$ARCH") "docker://${ref}" 2>/dev/null \
                   | jq -r '.Digest // empty' | sed 's/^sha256://')"

    if [ -z "$ghcr_digest" ]; then
        unverified=$((unverified + 1))
        unverified_names="${unverified_names} ${addon}"
        continue
    fi

    if [ "$baked_digest" = "$ghcr_digest" ]; then
        verified=$((verified + 1))
    else
        echo "FAIL: $addon $version is STALE — baked ${baked_digest:0:12} but GHCR has ${ghcr_digest:0:12}"
        failed=$((failed + 1))
    fi
done

echo "baked add-on images: ${checked}/${pin_count} pins present in the image" \
     "(${verified} digest-verified against GHCR, ${unverified} unverified)"
if [ -n "$unverified_names" ]; then
    echo "  unverified (registry unreadable — presence proven, freshness not):${unverified_names}"
fi

if [ "$failed" -gt 0 ]; then
    echo "FAIL: ${failed} of ${pin_count} pinned add-ons did not check out"
    exit 1
fi

# Belt and braces: the loop above cannot leave a pin uncounted without also
# incrementing `failed`, so this can only fire if someone edits the loop and
# breaks that invariant. It is here because "coverage silently dropped" is the
# exact defect this script replaces.
if [ "$checked" -ne "$pin_count" ]; then
    echo "FAIL: only ${checked} of ${pin_count} pins were inspected — coverage gap"
    exit 1
fi

exit 0
