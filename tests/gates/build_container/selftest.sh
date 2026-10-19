#!/usr/bin/env bash
# selftest.sh - scripts/check-build-container.sh must go RED on every way a build
# container can drift and GREEN on the pinned one (Odoo #1288).
#   must-fail/1.6-unpinned.Dockerfile  feat/1.6-haos18's Dockerfile before pinning (committed copy)
#   must-pass/pinned.Dockerfile        a pinned Dockerfile (committed copy)
#   mutations of the LIVE ./Dockerfile - each undoes one pin; the gate must name THAT finding
#   the live ./Dockerfile itself       must pass
# The gate is the live script, never a copy of its patterns.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$ROOT/scripts/check-build-container.sh"
LIVE="$ROOT/Dockerfile"
[[ -x "$GATE" && -s "$LIVE" ]] || { echo "FATAL: gate or Dockerfile missing"; exit 2; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0; ran=0
bad() { echo "  FAIL  $*"; fails=$((fails+1)); ran=$((ran+1)); }
ok()  { echo "  ok    $*"; ran=$((ran+1)); }

expect_fail() { # <name> <file> <finding-token>
  local out rc; out="$("$GATE" "$2" 2>&1)"; rc=$?
  if [[ $rc -eq 1 && "$out" == *"$3"* ]]; then ok "$1 -> red ($3)"; else bad "$1: rc=$rc, wanted rc=1 naming '$3': $out"; fi
}
expect_pass() { local out rc; out="$("$GATE" "$2" 2>&1)"; rc=$?; [[ $rc -eq 0 ]] && ok "$1 -> green" || bad "$1: rc=$rc: $out"; }

for f in "$HERE"/must-fail/*.Dockerfile; do
  [[ -e "$f" ]] || { bad "no must-fail fixtures found"; break; }
  out="$("$GATE" "$f" 2>&1)"; rc=$?
  [[ $rc -eq 1 ]] && ok "$(basename "$f") -> red" || bad "$(basename "$f"): rc=$rc (must be 1): $out"
done
for f in "$HERE"/must-pass/*.Dockerfile; do
  [[ -e "$f" ]] || { bad "no must-pass fixtures found"; break; }
  expect_pass "$(basename "$f")" "$f"
done
expect_pass "live Dockerfile" "$LIVE"

mut() { # <name> <sed-expr> <token>
  sed -E "$2" "$LIVE" > "$W/m.Dockerfile"
  cmp -s "$LIVE" "$W/m.Dockerfile" && { bad "mutation '$1' changed nothing (fixture rot)"; return; }
  expect_fail "mutation: $1" "$W/m.Dockerfile" "$3"
}
mut "FROM by tag only"            's#^(FROM [^@ ]+)@sha256:[0-9a-f]{64}#\1#'                     FROM-not-digest-pinned
mut "snapshot ARG floating"       's#^ARG DEBIAN_SNAPSHOT=.*#ARG DEBIAN_SNAPSHOT=latest#'        snapshot-timestamp-not-exact
mut "live mirror for main"        's#snapshot\.debian\.org/archive/debian/\$\{DEBIAN_SNAPSHOT\}/#deb.debian.org/debian/#' live-mirror-referenced
mut "live security mirror"        's#http://snapshot\.debian\.org/archive/debian-security/\$\{DEBIAN_SNAPSHOT\}/#http://security.debian.org/debian-security/#' live-mirror-referenced
mut "docker version floating"     's#^ARG DOCKER_VERSION=.*#ARG DOCKER_VERSION=latest#'          docker-version-not-pinned
mut "containerd version missing"  's#^ARG CONTAINERD_VERSION=.*#ARG CONTAINERD_VERSION=#'        containerd-version-not-pinned
mut "docker sha256 dropped"       's#k_sum=[0-9a-f]{64}#k_sum=#g'                                docker-sha256-missing-k_sum
mut "sha256 check removed"        's#sha256sum -c -#true#'                                       no-sha256sum-check
mut "docker installed by name"    's#\./docker-ce_\*\.deb#docker-ce#'                            docker-package-installed-by-name
mut "docker apt repo configured"  's#^ARG DOCKER_VERSION=#RUN echo deb https://download.docker.com/linux/debian/gpg > /etc/apt/sources.list.d/docker.list\nARG DOCKER_VERSION=#'  docker-apt-repo-configured
printf 'FROM debian:trixie\n' > "$W/min.Dockerfile"
expect_fail "minimal unpinned" "$W/min.Dockerfile" FROM-not-digest-pinned
: > "$W/empty.Dockerfile"
"$GATE" "$W/empty.Dockerfile" >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "empty file -> fail closed (2)" || bad "empty file must exit 2"
"$GATE" "$W/nonexistent" >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "missing file -> fail closed (2)" || bad "missing file must exit 2"

echo "build-container gate selftest: $ran checks, $fails failed"
[[ $ran -ge 15 && $fails -eq 0 ]]
