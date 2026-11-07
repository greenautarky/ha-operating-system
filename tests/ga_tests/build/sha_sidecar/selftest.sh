#!/usr/bin/env bash
# Fixtures for scripts/lib/sha-sidecar.sh (Odoo #1657): the bake's .sha256 sidecar
# must hold `<sha256>  <basename>` so `sha256sum -c` works next to the file.
#   * drives the LIVE ga_write_sha_sidecar (nothing stubbed); FAILS if it is not found
#   * must-verify: sidecar written for a path outside cwd verifies in the file's dir
#   * must-flag: the legacy container-path shape does NOT verify (proves the check can go red)
#   * consumer shapes: token-1 readers (awk / cut, as ga_build.sh, verify-sd.sh,
#     provision-e2e.sh, image_archive.py) give the same digest for new AND legacy shape
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$(cd "$HERE/../../../.." && pwd)/scripts/lib/sha-sidecar.sh"
pass=0 fail=0
_pass() { echo "  PASS  $1"; pass=$((pass+1)); }
_fail() { echo "  FAIL  $1"; fail=$((fail+1)); }
echo "=== sha-sidecar fixtures ==="
# shellcheck disable=SC1090
. "$LIB" 2>/dev/null
declare -F ga_write_sha_sidecar >/dev/null || { _fail "ga_write_sha_sidecar not found in $LIB"; exit 1; }
W="$(mktemp -d "${TMPDIR:-/home/user/.cache/claude-tmp}/shasc.XXXXXX")"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/build/ga_output/images"; I="$W/build/ga_output/images"
printf 'payload-%s\n' 1 2 3 > "$I/os-1.img.xz"; printf 'bundle\n' > "$I/os-1.raucb"
ga_write_sha_sidecar "$I/os-1.img.xz" && ga_write_sha_sidecar "$I/os-1.raucb" || _fail "writer returned non-zero"
for f in os-1.img.xz os-1.raucb; do
  line="$(cat "$I/$f.sha256")"
  [[ "$line" =~ ^[0-9a-f]{64}"  ""$f"$ ]] && _pass "$f.sha256 is '<sha256>  <basename>'" || _fail "$f.sha256 shape: $line"
  (cd "$I" && sha256sum -c --quiet "$f.sha256" >/dev/null 2>&1) && _pass "sha256sum -c $f.sha256 verifies next to the file" || _fail "sha256sum -c fails for $f"
  [[ "$(awk '{print $1}' "$I/$f.sha256")" == "$(cut -d' ' -f1 "$I/$f.sha256")" && "$(awk '{print $1}' "$I/$f.sha256")" == "$(sha256sum "$I/$f" | cut -d' ' -f1)" ]] \
    && _pass "token-1 readers (awk/cut) get the file's digest" || _fail "token-1 mismatch for $f"
done
# must-flag: legacy shape (container path) must not verify next to the file; token 1 stays identical
legacy="$W/legacy"; mkdir "$legacy"; cp "$I/os-1.raucb" "$legacy/"
printf '%s  /build/ga_output/images/os-1.raucb\n' "$(sha256sum "$I/os-1.raucb" | cut -d' ' -f1)" > "$legacy/os-1.raucb.sha256"
(cd "$legacy" && sha256sum -c --quiet os-1.raucb.sha256 >/dev/null 2>&1) && _fail "legacy shape unexpectedly verifies (check cannot go red)" || _pass "legacy container-path shape does NOT verify (check can go red)"
[[ "$(awk '{print $1}' "$legacy/os-1.raucb.sha256")" == "$(awk '{print $1}' "$I/os-1.raucb.sha256")" ]] && _pass "legacy and new shape: same token 1 (consumers tolerate both)" || _fail "token 1 differs"
# missing file fails closed
ga_write_sha_sidecar "$I/nope" 2>/dev/null && _fail "missing file did not fail" || _pass "missing file fails closed"
echo "=== $pass passed, $fail failed ==="; [[ $fail -eq 0 ]]
