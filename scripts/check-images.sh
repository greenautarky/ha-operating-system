#!/usr/bin/env bash
# Pre-build check: verify all required container images exist in their registries.
# Run this BEFORE starting the multi-hour OS build to catch missing images early.
#
# Usage: ./scripts/check-images.sh [stable.json URL or local path]
#
# Checks:
#   1. All images from stable.json (supervisor, core, cli, dns, audio, multicast, observer)
#   2. All addon images from addon-images.json
#
# Requires: skopeo (for anonymous registry checks) or curl + gh auth token

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default stable.json source
STABLE_JSON_URL="${1:-https://raw.githubusercontent.com/greenautarky/haos-version/main/stable.json}"
ADDON_IMAGES_JSON="${REPO_ROOT}/buildroot-external/package/hassio/addon-images.json"

# Architecture to check (iHost = armv7)
ARCH="${CHECK_ARCH:-armv7}"
MACHINE="${CHECK_MACHINE:-tinker}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

fail_count=0
pass_count=0
auth_count=0

# Distinguish "image is genuinely missing" from "we are not allowed to look".
#
# Since 2026-07-29 the ga_manager packages are PRIVATE on GHCR (deliberate —
# the artifact shipped the full addon source, see ADDON-IMAGE-DELIVERY.md).
# An unauthenticated probe of a private image returns 401/403, which reads
# exactly like "missing" to a naive check. Reporting that as FAIL would make
# the build refuse to start over a healthy registry; reporting it as OK would
# be a false green — the failure mode this repo keeps getting bitten by.
# So it is its own outcome: AUTH, counted separately, exit code 2.
#
# To check private images, authenticate first:
#   skopeo login ghcr.io -u <user> -p <read:packages token>
# On ga-builder this is already covered by /root/.docker/config.json.
_is_auth_error() {
    # skopeo/registry wording varies by version; match the stable substrings.
    grep -qiE 'unauthorized|authentication required|denied|403|401' <<<"$1"
}

check_image() {
    local image="$1"
    local tag="$2"
    local full="${image}:${tag}"
    local err=""

    if command -v skopeo >/dev/null 2>&1; then
        if skopeo inspect --raw "docker://${full}" >/dev/null 2>&1; then
            printf "${GREEN}  OK${NC}  %s\n" "$full"
            pass_count=$((pass_count + 1))
            return 0
        fi
        # Try with arch override for multi-arch images
        if err=$(skopeo inspect --override-arch arm --override-variant v7 --raw "docker://${full}" 2>&1 >/dev/null); then
            printf "${GREEN}  OK${NC}  %s (multi-arch)\n" "$full"
            pass_count=$((pass_count + 1))
            return 0
        fi
        if _is_auth_error "$err"; then
            printf "${YELLOW}AUTH${NC}  %s (private — not authenticated, existence UNVERIFIED)\n" "$full"
            auth_count=$((auth_count + 1))
            return 1
        fi
    else
        # Fallback: use Docker Hub/GHCR API via curl
        local registry="${image%%/*}"
        local repo="${image#*/}"
        local api_url=""

        case "$registry" in
            ghcr.io)
                api_url="https://ghcr.io/v2/${repo}/manifests/${tag}"
                ;;
            *)
                # Docker Hub or other registries — skip check
                printf "${YELLOW}SKIP${NC}  %s (no skopeo, cannot check non-GHCR)\n" "$full"
                return 0
                ;;
        esac

        # GHCR's token endpoint does NOT hand out an anonymous token for a
        # private repository — it answers
        #   {"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}
        # with no token field at all. So "private" has to be detected HERE, on
        # the token response; by the time we have an empty token there is
        # nothing left to distinguish it from a genuinely missing image.
        # (Measured 2026-07-29 against ga_manager-armv7 right after it was
        # switched to private.)
        local token_resp token
        token_resp=$(curl -s "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull" 2>/dev/null || true)
        if echo "$token_resp" | grep -qE '"code"[[:space:]]*:[[:space:]]*"(UNAUTHORIZED|DENIED|FORBIDDEN)"'; then
            printf "${YELLOW}AUTH${NC}  %s (private — not authenticated, existence UNVERIFIED)\n" "$full"
            auth_count=$((auth_count + 1))
            return 1
        fi
        token=$(echo "$token_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)

        if [ -n "$token" ]; then
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${token}" -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json" "$api_url" 2>/dev/null || echo "000")
            if [ "$http_code" = "200" ]; then
                printf "${GREEN}  OK${NC}  %s\n" "$full"
                pass_count=$((pass_count + 1))
                return 0
            fi
            # The anonymous token endpoint hands out a token for private repos
            # too — it just does not grant pull. 401/403 here means "private",
            # not "gone".
            if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
                printf "${YELLOW}AUTH${NC}  %s (private — not authenticated, existence UNVERIFIED)\n" "$full"
                auth_count=$((auth_count + 1))
                return 1
            fi
        fi
    fi

    printf "${RED}FAIL${NC}  %s\n" "$full"
    fail_count=$((fail_count + 1))
    return 1
}

# --- Check cache directory permissions ---
CACHE_DIR="${CACHE_DIR:-/cache/dl/hassio}"
if [ -d "$CACHE_DIR" ]; then
    stale_locks=$(find "$CACHE_DIR" -name '*.lock' ! -writable 2>/dev/null | wc -l)
    if [ "$stale_locks" -gt 0 ]; then
        printf "${YELLOW}WARN${NC}  Found %d stale lock file(s) in %s (wrong owner) — removing\n" "$stale_locks" "$CACHE_DIR"
        find "$CACHE_DIR" -name '*.lock' ! -writable -delete 2>/dev/null || true
    fi
fi

# --- Fetch stable.json ---
echo "=== Pre-build Image Availability Check ==="
echo ""

if [[ "$STABLE_JSON_URL" == http* ]]; then
    echo "Fetching stable.json from: $STABLE_JSON_URL"
    stable_json=$(curl -sf "$STABLE_JSON_URL") || { echo "ERROR: Cannot fetch stable.json"; exit 1; }
else
    echo "Reading stable.json from: $STABLE_JSON_URL"
    stable_json=$(cat "$STABLE_JSON_URL")
fi

# --- Check system images from stable.json ---
echo ""
echo "--- System Images (from stable.json) ---"

# Supervisor
sup_image=$(echo "$stable_json" | jq -r ".images.supervisor | sub(\"{arch}\"; \"${ARCH}\") | sub(\"{machine}\"; \"${MACHINE}\")")
sup_version=$(echo "$stable_json" | jq -r '.supervisor')
check_image "$sup_image" "$sup_version" || true

# Core
core_image=$(echo "$stable_json" | jq -r ".images.core | sub(\"{arch}\"; \"${ARCH}\") | sub(\"{machine}\"; \"${MACHINE}\")")
core_version=$(echo "$stable_json" | jq -r '.core')
check_image "$core_image" "$core_version" || true

# Other system components
for component in cli dns audio multicast observer; do
    comp_image=$(echo "$stable_json" | jq -r ".images.${component} | sub(\"{arch}\"; \"${ARCH}\") | sub(\"{machine}\"; \"${MACHINE}\")")
    comp_version=$(echo "$stable_json" | jq -r ".${component}")
    check_image "$comp_image" "$comp_version" || true
done

# --- Check addon images from addon-images.json ---
if [ -f "$ADDON_IMAGES_JSON" ]; then
    echo ""
    echo "--- Addon Images (from addon-images.json) ---"

    addon_count=$(jq '.addons | length' "$ADDON_IMAGES_JSON")
    for key in $(jq -r '.addons | keys[]' "$ADDON_IMAGES_JSON"); do
        addon_image=$(jq -r ".addons.\"${key}\".image | sub(\"{arch}\"; \"${ARCH}\")" "$ADDON_IMAGES_JSON")
        addon_version=$(jq -r ".addons.\"${key}\".version" "$ADDON_IMAGES_JSON")
        check_image "$addon_image" "$addon_version" || true
    done
fi

# --- vibe_addons lockstep with addon-images.json ---
#
# The OS bundle pins addon versions via addon-images.json. Provisioning
# installs from the public vibe_addons addon repo — so its config
# versions MUST match the bundle pins, or a freshly-provisioned device
# would land on whatever vibe_addons HEAD currently says (version drift).
# Match by `image:` (NOT slug — vibe_addons uses different naming, e.g.
# addon-images.json key `ga_tailscale` lives in vibe_addons/tailscale/
# with slug `ga_tailscale`; some addons use config.json, others config.yaml).
# Discipline: when bumping an addon in the bundle, bump vibe_addons/main
# in the same change set.
_read_addon_field() {
    # $1 = config file path (.yaml or .json), $2 = top-level field name
    local f="$1" field="$2"
    case "$f" in
        *.json) jq -r ".${field} // empty" "$f" 2>/dev/null ;;
        *)      awk -v F="$field" '$0 ~ "^"F":"{sub("^"F":[[:space:]]*", ""); gsub(/^"|"$/, ""); print; exit}' "$f" ;;
    esac
}

if [ -f "$ADDON_IMAGES_JSON" ] && command -v git >/dev/null 2>&1; then
    echo ""
    echo "--- vibe_addons lockstep with addon-images.json ---"
    VIBE_TMP=$(mktemp -d)
    trap 'rm -rf "$VIBE_TMP"' EXIT
    VIBE_REPO_URL="${VIBE_ADDONS_REPO_URL:-https://github.com/greenautarky/vibe_addons}"
    VIBE_REPO_REF="${VIBE_ADDONS_REPO_REF:-main}"
    if ! git clone --depth=1 --quiet --branch "$VIBE_REPO_REF" "$VIBE_REPO_URL" "$VIBE_TMP/vibe_addons" 2>/dev/null; then
        printf "${YELLOW}WARN${NC}: could not clone %s @ %s — skipping vibe_addons lockstep check\n" \
            "$VIBE_REPO_URL" "$VIBE_REPO_REF"
    else
        for key in $(jq -r '.addons | keys[]' "$ADDON_IMAGES_JSON"); do
            expected_image=$(jq -r ".addons.\"${key}\".image" "$ADDON_IMAGES_JSON")
            expected_version=$(jq -r ".addons.\"${key}\".version" "$ADDON_IMAGES_JSON")
            # Find the vibe_addons subdir whose config `image:` field == expected_image
            found_dir=""
            found_slug=""
            for dir in "$VIBE_TMP/vibe_addons"/*/; do
                cfg=""
                for c in "$dir/config.yaml" "$dir/config.json"; do
                    [ -f "$c" ] && cfg="$c" && break
                done
                [ -z "$cfg" ] && continue
                img=$(_read_addon_field "$cfg" image)
                if [ "$img" = "$expected_image" ]; then
                    found_dir="$dir"
                    found_slug=$(_read_addon_field "$cfg" slug)
                    found_version=$(_read_addon_field "$cfg" version)
                    break
                fi
            done
            if [ -z "$found_dir" ]; then
                printf "${RED}FAIL${NC}: addon-images.json[%s] image=%s has no matching addon in vibe_addons\n" \
                    "$key" "$expected_image"
                fail_count=$((fail_count + 1))
                continue
            fi
            if [ "$found_version" = "$expected_version" ]; then
                printf "${GREEN}OK${NC}: %s (slug=%s, dir=%s) version %s — vibe_addons in lockstep\n" \
                    "$key" "$found_slug" "$(basename "$found_dir")" "$found_version"
                pass_count=$((pass_count + 1))
            else
                printf "${RED}FAIL${NC}: %s version mismatch — addon-images.json=%s vibe_addons/%s=%s — bump one to match\n" \
                    "$key" "$expected_version" "$(basename "$found_dir")" "$found_version"
                fail_count=$((fail_count + 1))
            fi
        done
    fi
fi

# --- source-of-truth drift (the axis the lockstep check cannot see) ---
#
# The check above compares the bake pin to the add-on store. Both can be stale
# TOGETHER and it stays green: on 2026-07-29 addon-images.json and vibe_addons
# both said ga_manager 0.100.0 while the source repo was at 0.105.0. Five
# releases — including a fleet credential-rotation fix and three security
# changes — were built, published, and undeliverable, behind a green badge.
#
# The missing edge is published -> pin, and it is asked of the REGISTRY rather
# than of the source repository. The first version of this check cloned each
# add-on's repo and read its declared version. Two things were wrong with that:
#
#   1. For mosquitto, zigbee2mqtt and tailscale the default branch is NOT the
#      source. They publish from long-lived `ga-build/**` branches, and their
#      default branch still names the UPSTREAM image version — `MQTT` master
#      says 6.4.1 while we ship 7.1.2. A repo-based check reports "pin AHEAD of
#      source", i.e. noise pointing the wrong way, which is how a check earns
#      being ignored. Fixing that needs a hand-maintained per-add-on ref, and a
#      hand-maintained constant is how this goes stale again.
#   2. It could not run where it matters most. The build executes inside a
#      container with registry credentials but no GitHub token, so every private
#      add-on came out SKIP — honest, but useless exactly at build time.
#
# The registry answers both. `skopeo list-tags` uses the same credentials the
# build already requires to pull these images, so it works in the container, it
# needs no map, and it covers every add-on rather than the one that happened to
# be listed. It also asks the question we actually care about: an image exists
# that no device can reach.
#
# Advisory by design — a canary image published for testing legitimately leads
# the pin, and failing on that would make the check noise again.
# GA_SOURCE_DRIFT_STRICT=1 turns it fatal; ga_build.sh sets that, because
# leading the pin is fine on a Tuesday afternoon and not in the build that
# becomes an image. Set GA_SOURCE_DRIFT_STRICT=0 for a deliberate older pin.
if [ -f "$ADDON_IMAGES_JSON" ] && command -v skopeo >/dev/null 2>&1; then
    echo ""
    echo "--- delivery drift (pinned vs newest tag actually published) ---"
    drift_seen=0
    drift_fatal=0
    for key in $(jq -r '.addons | keys[]' "$ADDON_IMAGES_JSON"); do
        image=$(jq -r ".addons.\"${key}\".image" "$ADDON_IMAGES_JSON" | sed "s/{arch}/${ARCH}/")
        pinned=$(jq -r ".addons.\"${key}\".version // empty" "$ADDON_IMAGES_JSON")
        [ -z "$pinned" ] && continue
        # Only add-ons we publish ourselves — an upstream vendor's newest tag is
        # not something this repo is behind on.
        case "$image" in *ghcr.io/greenautarky/*) : ;; *) continue ;; esac

        # `|| newest=""` is load-bearing, not defensive noise. This script runs
        # under `set -euo pipefail`, and this pipeline fails in two ordinary
        # situations: skopeo cannot list a PRIVATE package (no registry
        # credential on a GitHub-hosted runner), and grep exits 1 when an
        # add-on has no numeric tags at all. Under pipefail either one makes
        # the assignment fail, and `set -e` then aborts the whole script — so
        # the SKIP branch three lines below, written precisely for "could not
        # list tags", was structurally unreachable.
        #
        # The effect was not a missing message. It was a required status check
        # dying mid-loop with a bare `exit 1`: every add-on after the first
        # private one went unexamined, and the log gave no reason. Found when
        # ga_manager became private and the job started failing on every PR
        # while master's last run was still green.
        newest=$(skopeo list-tags "docker://${image}" 2>/dev/null \
            | jq -r '.Tags[]?' 2>/dev/null \
            | grep -E '^[0-9]+([.][0-9]+)+' \
            | sort -V | tail -1) || newest=""

        if [ -z "$newest" ]; then
            # Not agreement. Say so.
            printf "${YELLOW}SKIP${NC}: %s — could not list tags for %s (not counted as agreement)\n" \
                "$key" "$image"
            continue
        fi
        if [ "$newest" = "$pinned" ]; then
            printf "${GREEN}OK${NC}: %s pinned %s == newest published\n" "$key" "$pinned"
        elif [ "$(printf '%s\n%s\n' "$pinned" "$newest" | sort -V | tail -1)" = "$pinned" ]; then
            # Pin ahead of anything published. check_image above already fails
            # if the pinned tag is missing outright, so this is the narrower
            # case of a tag that exists but sorts below the pin — worth a line,
            # not a failure.
            printf "${YELLOW}NOTE${NC}: %s pinned %s is ahead of the newest listed tag %s\n" \
                "$key" "$pinned" "$newest"
        else
            drift_seen=$((drift_seen + 1))
            printf "${YELLOW}DRIFT${NC}: %s pinned %s but %s is published — that image is not reachable by any device until the pin follows\n" \
                "$key" "$pinned" "$newest"
            printf "        fix: bump addon-images.json AND the vibe_addons store entry to %s in one change set\n" "$newest"
        fi
    done
    if [ "$drift_seen" -gt 0 ] && [ "${GA_SOURCE_DRIFT_STRICT:-0}" = "1" ]; then
        # Deliberately NOT folded into fail_count: that counter's summary line
        # says "image(s) not found in registry", and the image here exists —
        # it is the pin that is behind. A wrong reason sends the next person
        # looking at the registry instead of at the pin.
        drift_fatal=1
    fi
fi

# --- Summary ---
echo ""
echo "=== Summary ==="
echo "Passed:       ${pass_count}"
echo "Failed:       ${fail_count}"
echo "Unverified:   ${auth_count} (private, no registry credentials)"

if [ "${drift_fatal:-0}" = "1" ]; then
    echo ""
    printf "${RED}ERROR: add-on(s) pinned behind their source repo (GA_SOURCE_DRIFT_STRICT=1).${NC}\n"
    printf "${RED}The images exist — the pin does not point at them. Bump the pin, not the registry.${NC}\n"
    exit 1
fi

if [ "$fail_count" -gt 0 ]; then
    echo ""
    printf "${RED}ERROR: ${fail_count} image(s) not found in registry. Fix before building.${NC}\n"
    exit 1
elif [ "$auth_count" -gt 0 ]; then
    echo ""
    printf "${YELLOW}UNVERIFIED: ${auth_count} private image(s) could not be checked — no credentials.${NC}\n"
    printf "${YELLOW}This is NOT a pass. The images may or may not exist.${NC}\n"
    printf "${YELLOW}Authenticate first:  skopeo login ghcr.io -u <user> -p <read:packages token>${NC}\n"
    exit 2
else
    printf "${GREEN}All images available. Safe to build.${NC}\n"
    exit 0
fi
