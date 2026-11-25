#!/bin/bash
# check_images_curl -- without skopeo, check_image() of the LIVE scripts/check-images.sh asks GHCR with curl.
# GHCR answers 404 when the stored manifest type is not in the Accept header, so a missing type reads as
# "image missing" (ga_influxdbv1-aarch64:0.0.26, an OCI manifest, 2026-11-25). The curl stand-in answers
# like GHCR: 200 only when the Accept header names the stored type. The function is cut out of the live
# script; if that finds nothing, FAIL. Zero cases = FAIL.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; LIVE="${CHECK_IMAGES:-$HERE/../../../scripts/check-images.sh}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0; ran=0
ok()  { ran=$((ran+1)); echo "  ok    $1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); echo "  FAIL  $1"; }
sed -n '/^check_image() {/,/^}/p' "$LIVE" > "$W/fn.sh"
grep -q 'Accept:' "$W/fn.sh" && grep -q '^}' "$W/fn.sh" || { echo "FAIL: check_image() with its Accept header not found in $LIVE"; exit 1; }
cat > "$W/drive.sh" <<'D'
set -u
GREEN= RED= YELLOW= NC=; pass_count=0 fail_count=0 auth_count=0
command() { if [ "${2:-}" = skopeo ]; then return 1; fi; builtin command "$@"; }   # no skopeo here
curl() {
  case "$*" in *ghcr.io/token*) echo '{"token":"t"}'; return 0 ;; esac
  local a accept=""
  for a in "$@"; do case "$a" in Accept:*) accept="${a#Accept: }" ;; esac; done
  case ",${accept}," in *",${STORED},"*) printf 200 ;; *) printf 404 ;; esac
}
. "$1"
check_image ghcr.io/greenautarky/x-aarch64 1.0 >/dev/null
echo "pass=$pass_count fail=$fail_count auth=$auth_count"
D
t() {  # <stored type> <expected line>
  got="$(STORED="$1" bash "$W/drive.sh" "$W/fn.sh" 2>&1)"
  if [ "$got" = "$2" ]; then ok "stored as $1 -> $2"; else bad "stored as $1 -> '$got', expected '$2'"; fi
}
t application/vnd.oci.image.manifest.v1+json "pass=1 fail=0 auth=0"
t application/vnd.oci.image.index.v1+json "pass=1 fail=0 auth=0"
t application/vnd.docker.distribution.manifest.v2+json "pass=1 fail=0 auth=0"
t application/vnd.docker.distribution.manifest.list.v2+json "pass=1 fail=0 auth=0"
t no-such-image "pass=0 fail=1 auth=0"
echo "$ran cases, $fails failed"; [ "$ran" -eq 5 ] && [ "$fails" -eq 0 ]
