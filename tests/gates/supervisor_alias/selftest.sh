#!/usr/bin/env bash
# The 1.6 image (HAOS 18.x) names the Supervisor unit haos-supervisor.service.
# Components synced into the image and scripts written for the 1.5 line name
# it hassos-supervisor.service — ga-bootstrap.service has
# Requires=hassos-supervisor.service, and a Requires= on a unit that does not
# exist drops the dependent's start job with nothing but "Result: dependency".
# The GA layer ships hassos-supervisor.service as an alias symlink to
# haos-supervisor.service, the same compatibility upstream HAOS 18.x keeps for
# hassos-config.service.
#
# This drives the real systemd unit loader (systemd-analyze --root verify) on
# a staged root: upstream's haos-supervisor.service as the build sees it
# (scripts/apply-haos-patches.sh --cat), the GA alias taken from the LIVE tree,
# and a consumer with Requires=/After=hassos-supervisor.service.
#   must-pass: with the alias, the loader does not report the name missing
#   must-fail: without it, it reports "Unit hassos-supervisor.service not found"
# A loader that cannot run, or a live tree without the alias, is a FAILURE.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; repo="$(cd "$here/../../.." && pwd)"
. "$repo/scripts/lib/tree-paths.sh"
alias_src="$repo/$GA_LAYER_DIR/rootfs-overlay/etc/systemd/system/hassos-supervisor.service"
command -v systemd-analyze >/dev/null || { echo "FAIL: systemd-analyze not available"; exit 1; }
[ -L "$alias_src" ] || { echo "FAIL: $alias_src is not a symlink in the live tree"; exit 1; }
[ "$(readlink "$alias_src")" = /usr/lib/systemd/system/haos-supervisor.service ] \
  || { echo "FAIL: $alias_src points at '$(readlink "$alias_src")', not /usr/lib/systemd/system/haos-supervisor.service"; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
stage() { # DIR WITH_ALIAS
  mkdir -p "$1/usr/lib/systemd/system" "$1/etc/systemd/system" "$1/usr/sbin"
  "$repo/scripts/apply-haos-patches.sh" --cat buildroot-external/rootfs-overlay/usr/lib/systemd/system/haos-supervisor.service \
    > "$1/usr/lib/systemd/system/haos-supervisor.service" || return 1
  printf '#!/bin/sh\n' > "$1/usr/sbin/haos-supervisor"; chmod +x "$1/usr/sbin/haos-supervisor"
  printf '[Unit]\nDescription=consumer\nDefaultDependencies=no\nAfter=hassos-supervisor.service\nRequires=hassos-supervisor.service\n[Service]\nType=oneshot\nExecStart=/usr/sbin/haos-supervisor\n' \
    > "$1/etc/systemd/system/ga-consumer.service"
  [ "$2" = yes ] && cp -P "$alias_src" "$1/etc/systemd/system/"
  return 0
}
verify() { systemd-analyze --root="$1" verify ga-consumer.service 2>&1; }
bad=0
stage "$tmp/with" yes || { echo "FAIL: cannot stage (haos/ checked out?)"; exit 1; }
out="$(verify "$tmp/with")"
if grep -q 'Unit ga-consumer.service not found\|unrecognized option\|invalid option' <<<"$out"; then
  echo "FAIL: the unit loader did not run on the staged root :: $out"; exit 1
fi
# Positive evidence, not just a missing message: the loader must have gone
# THROUGH the alias into haos-supervisor.service — either it finished, or the
# first unit it could not find is one of haos-supervisor.service's own
# dependencies (the staged root carries no docker/dbus units).
deps="$(sed -nE 's/^(Requires|Wants|After|BindsTo|Requisite)=//p' "$tmp/with/usr/lib/systemd/system/haos-supervisor.service" | tr ' ' '\n' | sed '/^$/d')"
missing="$(sed -nE 's/.*Unit ([^ ]+) not found.*/\1/p' <<<"$out" | head -1)"
if [ -z "$missing" ] || grep -qxF -- "$missing" <<<"$deps"; then
  echo "  ok    must-pass/with-alias (resolved into haos-supervisor.service${missing:+; next missing: its dependency $missing})"
else echo "  FAIL  must-pass/with-alias: stopped at '$missing', not inside haos-supervisor.service :: $out"; bad=1; fi
stage "$tmp/without" no
out="$(verify "$tmp/without")"
if grep -q 'Unit hassos-supervisor.service not found' <<<"$out"; then echo "  ok    must-fail/without-alias (the loader reports the name missing)"
else echo "  FAIL  must-fail/without-alias: the loader did not report the missing unit :: $out"; bad=1; fi
echo "2 cases ran"
exit "$bad"
