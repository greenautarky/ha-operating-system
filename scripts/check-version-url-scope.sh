#!/usr/bin/env bash
# check-version-url-scope.sh — the version branch a bake reads must fit the release.
#
# Usage: scripts/check-version-url-scope.sh [hassio.mk] [version.yaml]
#        (defaults: the live files of this tree)
#
# hassio.mk's HASSIO_VERSION_URL decides which {channel}.json the build bakes
# Supervisor, Core and plugins from. It is BUILD-TIME ONLY: a flashed device
# polls the URL compiled into the GA Supervisor (haos-version/main/), whatever
# the image was baked from. So a bake from a candidate branch ships components
# the fleet's main has not promoted — legitimate for a release candidate
# (ADR-0037 dress rehearsal: candidate/stable-1.4 for BOSv1.4.0-rc5), wrong for
# a final release, which must bake exactly what the fleet polls.
#
# Rules (fail closed — anything unreadable is a failure, never a pass):
#   * the URL is greenautarky/haos-version on raw.githubusercontent.com, ending in /
#   * branch `main`               -> any release
#   * branch `candidate/<name>`   -> only a gaos_release ending in -rc<N>
#   * any other branch            -> refused (a stale WIP pointer outlived a
#                                    release once: release/v1.2-rebuild)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MK="${1:-$ROOT/buildroot-external/package/hassio/hassio.mk}"
VY="${2:-$ROOT/version.yaml}"

fail() { echo "version-url-scope: FAIL: $*" >&2; exit 1; }

[ -f "$MK" ] || fail "hassio.mk not found at $MK"
[ -f "$VY" ] || fail "version.yaml not found at $VY"

URL="$(sed -nE 's/^HASSIO_VERSION_URL[[:space:]]*\??=[[:space:]]*"([^"]+)"[[:space:]]*$/\1/p' "$MK" | head -1)"
[ -n "$URL" ] || fail "no HASSIO_VERSION_URL assignment found in $MK — the extraction lost its subject"
REL="$(awk '/^gaos_release:/{print $2; exit}' "$VY")"
[ -n "$REL" ] || fail "no gaos_release in $VY"

PREFIX="https://raw.githubusercontent.com/greenautarky/haos-version/"
case "$URL" in
  "$PREFIX"*/) ;;
  *) fail "HASSIO_VERSION_URL='$URL' is not ${PREFIX}<branch>/" ;;
esac
BRANCH="${URL#"$PREFIX"}"; BRANCH="${BRANCH%/}"

case "$BRANCH" in
  main)
    echo "version-url-scope: OK: $REL bakes from main (what the fleet polls)"
    ;;
  candidate/?*)
    if [[ "$REL" =~ -rc[0-9]+$ ]]; then
      echo "version-url-scope: OK: $REL is a release candidate; bakes from $BRANCH."
      echo "  NOTE: devices flashed from it still POLL haos-version/main at runtime."
    else
      fail "$REL is a final release but bakes from $BRANCH. A final release bakes from main — promote the candidate to main and point HASSIO_VERSION_URL back at main first."
    fi
    ;;
  *)
    fail "branch '$BRANCH' is neither main nor candidate/<name>"
    ;;
esac
