#!/usr/bin/env bash
# check-version-url-scope.sh — the version branch a bake reads must fit the release.
#
# Usage: scripts/check-version-url-scope.sh [hassio.mk] [version.yaml]
#        (defaults: the live files of this tree)
#
# hassio.mk's HASSIO_VERSION_URL decides which {channel}.json the build bakes
# Supervisor, Core and plugins from. A bake from a candidate branch ships
# components the fleet's main has not promoted — legitimate for a release
# candidate (ADR-0037 dress rehearsal: candidate/stable-1.4 for BOSv1.4.0-rc5),
# wrong for a final release, which must bake exactly what the fleet polls.
#
# The same value is BAKED into the image as /etc/ga-version-url (hassio.mk
# HASSIO_INSTALL_TARGET_CMDS), and from GA Supervisor 2025.11.5.6 that file is
# what a device POLLS at runtime (absent or invalid -> main, with a warning;
# older Supervisors ignore it and poll main). This gate evaluates the real
# install recipe (scripts/probe-ga-version-url.sh) and judges the file the image
# would carry, not only the make variable.
#
# Rules (fail closed — anything unreadable is a failure, never a pass):
#   * the URL is greenautarky/haos-version on raw.githubusercontent.com, ending in /
#   * the image carries /etc/ga-version-url, exactly one line
#   * a FINAL release (gaos_release without -rc<N>): /etc/ga-version-url is main
#   * /etc/ga-version-url equals HASSIO_VERSION_URL (one source, not two)
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

# What the image would carry: run hassio.mk's install recipe into a scratch dir.
PROBE="$(mktemp -d)" || fail "mktemp failed"
trap 'rm -rf "$PROBE" "$PROBE.err"' EXIT
"$ROOT/scripts/probe-ga-version-url.sh" "$MK" "$PROBE" >/dev/null 2>"$PROBE.err" \
  || fail "could not evaluate the install recipe of $MK: $(head -c 300 "$PROBE.err")"
GVU="$PROBE/etc/ga-version-url"
[ -f "$GVU" ] || fail "the image would carry no /etc/ga-version-url (hassio.mk HASSIO_INSTALL_TARGET_CMDS does not write it) — the Supervisor would poll main whatever this image was baked from"
[ "$(wc -l < "$GVU")" = 1 ] || fail "/etc/ga-version-url is not exactly one line"
FILE_URL="$(cat "$GVU")"
if [[ ! "$REL" =~ -rc[0-9]+$ ]] && [ "$FILE_URL" != "${PREFIX}main/" ]; then
  fail "$REL is a final release but its /etc/ga-version-url is '$FILE_URL'. A final release must carry ${PREFIX}main/ — devices poll this file at runtime."
fi
[ "$FILE_URL" = "$URL" ] || fail "/etc/ga-version-url '$FILE_URL' differs from HASSIO_VERSION_URL '$URL' — the image would poll another branch than it was baked from"

case "$BRANCH" in
  main)
    echo "version-url-scope: OK: $REL bakes from main (what the fleet polls)"
    ;;
  candidate/?*)
    if [[ "$REL" =~ -rc[0-9]+$ ]]; then
      echo "version-url-scope: OK: $REL is a release candidate; bakes from $BRANCH."
      echo "  NOTE: its /etc/ga-version-url names $BRANCH too; Supervisor >= 2025.11.5.6 polls it, an older one polls main."
    else
      fail "$REL is a final release but bakes from $BRANCH. A final release bakes from main — promote the candidate to main and point HASSIO_VERSION_URL back at main first."
    fi
    ;;
  *)
    fail "branch '$BRANCH' is neither main nor candidate/<name>"
    ;;
esac
