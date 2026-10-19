#!/usr/bin/env bash
# check-build-container.sh <Dockerfile> - the build container must be reproducible (Odoo #1288).
#
# A build container whose inputs can move is a build that works until the day
# it is rebuilt: Debian 11's live index began listing packages that 404 on
# 2026-08-31, and the only working copy was one cached image on the builder.
# This asserts that every external input of the Dockerfile is pinned:
#   1  every FROM carries a content digest (@sha256:<64 hex>)
#   2  ARG DEBIAN_SNAPSHOT is an exact timestamp, and apt reads ONLY
#      snapshot.debian.org at that timestamp (debian + debian-security)
#   3  no live Debian mirror is referenced (non-comment lines)
#   4  Docker's apt repository is not configured; docker-ce / docker-ce-cli /
#      containerd.io are installed from .deb files pinned by exact version
#      (ARG DOCKER_VERSION / CONTAINERD_VERSION) and SHA-256 for amd64 + arm64
#   5  the three downloads are verified with sha256sum -c
# Exit 0 = pinned, 1 = findings (printed), 2 = unusable input (fail closed).
set -uo pipefail
df="${1:-}"
[[ -n "$df" && -s "$df" ]] || { echo "check-build-container: no Dockerfile at '${df}'" >&2; exit 2; }
code="$(grep -v '^[[:space:]]*#' "$df")"
bad=""
add() { bad+="$1 "; }

froms="$(grep -E '^[[:space:]]*FROM[[:space:]]' <<<"$code")"
[[ -n "$froms" ]] || { echo "check-build-container: no FROM in $df" >&2; exit 2; }
while IFS= read -r l; do
  grep -qE '^[[:space:]]*FROM[[:space:]]+[^[:space:]]+@sha256:[0-9a-f]{64}([[:space:]]|$)' <<<"$l" || add "FROM-not-digest-pinned"
done <<<"$froms"

grep -qE '^ARG DEBIAN_SNAPSHOT=[0-9]{8}T[0-9]{6}Z$' <<<"$code" || add "snapshot-timestamp-not-exact"
grep -qE 'snapshot\.debian\.org/archive/debian/\$\{DEBIAN_SNAPSHOT\}/ [a-z]+ main' <<<"$code" || add "apt-not-on-snapshot"
grep -qE 'snapshot\.debian\.org/archive/debian-security/\$\{DEBIAN_SNAPSHOT\}/ [a-z]+-security main' <<<"$code" || add "apt-security-not-on-snapshot"
grep -qE '(^|[^a-z.])(deb|security|ftp|httpredir)\.debian\.org' <<<"$code" && add "live-mirror-referenced"

grep -qE 'download\.docker\.com/linux/debian/(gpg|dists/[^/]+/stable[^/]*$)|docker\.(list|sources)|keyrings/docker' <<<"$code" && add "docker-apt-repo-configured"
grep -vE 'dpkg-query' <<<"$code" | grep -qE '(^|[[:space:]])(docker-ce|docker-ce-cli|containerd\.io)([[:space:]\\]|$)' && add "docker-package-installed-by-name"
grep -qE '^ARG DOCKER_VERSION=[0-9]+:[0-9][^ ]+$' <<<"$code" || add "docker-version-not-pinned"
grep -qE '^ARG CONTAINERD_VERSION=[0-9][^ ]+$' <<<"$code" || add "containerd-version-not-pinned"
for v in d_sum c_sum k_sum; do
  n="$(grep -oE "${v}=[0-9a-f]{64}" <<<"$code" | wc -l)"
  [[ "$n" -ge 2 ]] || add "docker-sha256-missing-${v}(${n}/2-arches)"
done
grep -q 'sha256sum -c' <<<"$code" || add "no-sha256sum-check"

if [[ -z "$bad" ]]; then
  echo "check-build-container: $df pinned (base digest, exact apt snapshot, docker debs by version+sha256)"
  exit 0
fi
echo "check-build-container: $df is NOT reproducible: ${bad}" >&2
exit 1
