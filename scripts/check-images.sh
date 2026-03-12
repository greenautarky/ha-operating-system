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

check_image() {
    local image="$1"
    local tag="$2"
    local full="${image}:${tag}"

    if command -v skopeo >/dev/null 2>&1; then
        if skopeo inspect --raw "docker://${full}" >/dev/null 2>&1; then
            printf "${GREEN}  OK${NC}  %s\n" "$full"
            pass_count=$((pass_count + 1))
            return 0
        fi
        # Try with arch override for multi-arch images
        if skopeo inspect --override-arch arm --override-variant v7 --raw "docker://${full}" >/dev/null 2>&1; then
            printf "${GREEN}  OK${NC}  %s (multi-arch)\n" "$full"
            pass_count=$((pass_count + 1))
            return 0
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

        local token
        token=$(curl -s "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)

        if [ -n "$token" ]; then
            local http_code
            http_code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${token}" -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json" "$api_url" 2>/dev/null || echo "000")
            if [ "$http_code" = "200" ]; then
                printf "${GREEN}  OK${NC}  %s\n" "$full"
                pass_count=$((pass_count + 1))
                return 0
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

# --- Summary ---
echo ""
echo "=== Summary ==="
echo "Passed: ${pass_count}"
echo "Failed: ${fail_count}"

if [ "$fail_count" -gt 0 ]; then
    echo ""
    printf "${RED}ERROR: ${fail_count} image(s) not found in registry. Fix before building.${NC}\n"
    exit 1
else
    printf "${GREEN}All images available. Safe to build.${NC}\n"
    exit 0
fi
