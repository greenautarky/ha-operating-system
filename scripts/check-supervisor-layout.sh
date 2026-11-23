#!/usr/bin/env bash
# Assert that the pinned Supervisor image is a SUPERVISOR, not an add-on base.
#
# WHY THIS EXISTS (2026-11-06): ghcr.io/greenautarky/armv7-hassio-supervisor:
# 2026.10.5.1 was built FROM the GA add-on base, whose s6-overlay carries the
# add-on boot oneshots base-addon-banner and base-addon-log-level. Inside a
# Supervisor image they ask the Supervisor API (this very container) for the
# add-on's config, fail ("Unknown log_level"), and s6 stops the container ~7 s
# after start. The image built, was present, correctly versioned and in the
# right namespace; every existing check was green; every fresh flash had no
# Supervisor. availability (check-images.sh) and Core namespace
# (check-supervisor-core-image.sh) cannot see this: it is a property of the
# image's s6 layout.
#
# Static: `docker create` + `export | tar -t`, never starts the image, so it
# works for foreign architectures without qemu.
#
# Usage:
#   scripts/check-supervisor-layout.sh                  # pin in version.yaml, armv7 (+aarch64 when the pin is 2026.10 or later)
#   scripts/check-supervisor-layout.sh <image-ref> [platform]
#   scripts/check-supervisor-layout.sh --listing FILE   # offline: FILE is a `tar -t` listing (self-test)
# Exit: 0 = Supervisor layout, 1 = add-on base layout, 2 = BROKEN CHECK (could
# not read / read nothing). "I could not look" is not "nothing to see".
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
die_broken() { echo "BROKEN CHECK: $*" >&2; exit 2; }

judge() {  # <listing-file> <label>
  local list="$1" label="$2" fail=0
  [ -s "$list" ] || die_broken "empty listing for $label - nothing was inspected"
  for must in etc/services.d/supervisor/run etc/services.d/watchdog/run; do
    grep -qx "$must" "$list" || { echo "FAIL: $label lacks $must - not a Supervisor image" >&2; fail=1; }
  done
  grep -qE 'etc/s6-rc/sources/fix-attrs/$' "$list" \
    || die_broken "$label: no s6-rc sources in the listing - cannot judge the s6 layout"
  local bad
  bad=$(grep -E 's6-rc/(sources|scripts)/.*base-addon' "$list" || true)
  if [ -n "$bad" ]; then
    echo "FAIL: $label carries the add-on base's boot oneshots (container exits ~7 s after start):" >&2
    echo "$bad" | head -8 >&2
    fail=1
  fi
  if [ "$fail" -eq 0 ]; then echo "OK: $label has a Supervisor s6 layout ($(wc -l < "$list") relevant entries)"; fi
  return "$fail"
}

if [ "${1:-}" = "--listing" ]; then
  [ -f "${2:-}" ] || die_broken "listing ${2:-} not found"
  judge "$2" "$2"; exit $?
fi

check_ref() {  # <ref> <platform>
  local ref="$1" plat="$2" cid tmp
  command -v docker >/dev/null 2>&1 || die_broken "docker is required"
  docker pull -q --platform "$plat" "$ref" >/dev/null 2>&1 || die_broken "cannot pull $ref for $plat"
  cid=$(docker create --platform "$plat" "$ref" x 2>/dev/null) || die_broken "cannot create a container from $ref"
  tmp=$(mktemp)
  docker export "$cid" | tar -t > "$tmp" 2>/dev/null
  docker rm -f "$cid" >/dev/null 2>&1
  judge "$tmp" "$ref ($plat)"; local rc=$?
  rm -f "$tmp"; return "$rc"
}

if [ $# -ge 1 ]; then
  check_ref "$1" "${2:-linux/arm/v7}"; exit $?
fi

VERSION_YAML="${REPO_ROOT}/version.yaml"
[ -f "$VERSION_YAML" ] || die_broken "version.yaml not found at $VERSION_YAML"
pin=$(sed -nE 's/^[[:space:]]*homeassistant_supervisor:[[:space:]]*"?([^"[:space:]#]+)"?.*/\1/p' "$VERSION_YAML" | head -1)
[ -n "$pin" ] || die_broken "no homeassistant_supervisor pin in version.yaml"
rc=0
check_ref "ghcr.io/greenautarky/armv7-hassio-supervisor:${pin}" linux/arm/v7 || rc=$?
case "$pin" in
  2026.1[0-9].*|202[7-9].*|20[3-9]*)  # GA aarch64 Supervisor exists from the 2026.10 line
    check_ref "ghcr.io/greenautarky/aarch64-hassio-supervisor:${pin}" linux/arm64 || { r=$?; [ "$rc" -eq 1 ] || rc=$r; } ;;
  *) echo "SKIP aarch64: pin $pin predates the GA aarch64 Supervisor (2026.10)" ;;
esac
exit "$rc"
