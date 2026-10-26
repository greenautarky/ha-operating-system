#!/usr/bin/env bash
# verify-apparmor-profile.sh <profile> — does <profile> match the ONE pin of the
# Supervisor AppArmor profile (buildroot-external/apparmor/hassio-supervisor.sha256)?
#
# Exit 0 and one "ok" line when it does; exit 1 with the reason otherwise:
# profile missing, pin file missing, not exactly one well-formed pin line, or a
# sha256 mismatch. Every consumer calls this one script, so they cannot
# disagree about the rule:
#   post-build.d/89-apparmor-profile.sh   the rootfs copy haos-apparmor loads
#   create-data-partition.sh (0132)       the data partition pre-seed
#   run_build_tests.sh AA-PIN-01          the built image
#
# GA_APPARMOR_PIN_FILE overrides the pin file (self-tests only).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN_FILE="${GA_APPARMOR_PIN_FILE:-$HERE/../apparmor/hassio-supervisor.sha256}"
PROFILE="${1:-}"

fail() { echo "apparmor-profile: FAIL: $*" >&2; exit 1; }

[ -n "$PROFILE" ] || fail "usage: $0 <profile>"
[ -f "$PIN_FILE" ] || fail "pin file $PIN_FILE not found"
[ -f "$PROFILE" ] || fail "profile $PROFILE not found"

# Exactly one pin line, "<64 hex>  hassio-supervisor"; comments and blank lines
# allowed. Zero or two pins is a broken pin file, never "use the first".
mapfile -t pins < <(grep -vE '^[[:space:]]*(#|$)' "$PIN_FILE" || true)
[ "${#pins[@]}" -eq 1 ] || fail "pin file $PIN_FILE must hold exactly one pin line, has ${#pins[@]}"
[[ "${pins[0]}" =~ ^([0-9a-f]{64})\ \ hassio-supervisor$ ]] \
    || fail "pin line in $PIN_FILE is not '<sha256>  hassio-supervisor'"
want="${BASH_REMATCH[1]}"

got="$(sha256sum "$PROFILE" | cut -d' ' -f1)"
[ "$got" = "$want" ] || fail "sha256 mismatch for $PROFILE: got $got, pinned $want — re-pin only in a reviewed PR that changes profile and pin together"
echo "apparmor-profile: ok ($PROFILE = pinned sha256 ${want:0:12}...)"
