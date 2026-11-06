#!/bin/bash
# build_tests_board_arch -- the build suite (tests/ga_tests/run_build_tests.sh) judges BLD
# (Core tag), VER-09 (Supervisor digest) and VER-10 (baked add-ons) per BOARD: the iHost
# against armv7 and the shared pin file (unchanged), the DSGW-210 against aarch64, its own
# pin file, and a -dev Core only on the dev channel with a -devN label.
#
# The LIVE runner is driven on fixture bakes (version.json + images/ with the tar names
# fetch-addon-images.sh writes). Only `skopeo` (the registry) is replaced by a stand-in
# that answers per platform flag: the arm64 digest D1 for --override-arch arm64, a
# different one (the armv7 digest) for arm/v7. That is exactly the defect: a DSGW tar judged
# against the armv7 digest. The subject (the runner and the checker) is never stubbed.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RUNNER="$ROOT/tests/ga_tests/run_build_tests.sh"
# shellcheck source=../../../scripts/lib/tree-paths.sh
. "$ROOT/scripts/lib/tree-paths.sh"
command -v jq >/dev/null || { echo "FATAL: jq missing"; exit 2; }
W="$(mktemp -d -t bba-XXXXXX)"
OUTD="$ROOT/ga_output-bba-fixture.$$"      # the runner finds the source tree as OUT/..
trap 'rm -rf "$W" "$OUTD"' EXIT
fails=0; ran=0
ok()  { ran=$((ran+1)); echo "  ok    $1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); echo "  FAIL  $1"; }
[ -r "$RUNNER" ] || { echo "FATAL: runner unreadable"; exit 2; }

D1=$(printf 'a%.0s' $(seq 64))   # the digest of the arm64 / pinned image
D2=$(printf 'b%.0s' $(seq 64))   # the armv7 digest of the same tag
mkdir -p "$W/bin"
cat > "$W/bin/skopeo" <<SK
#!/bin/bash
case "\$*" in
  *"--override-arch arm64"*) echo '{"Digest":"sha256:$D1"}' ;;
  *"--override-arch arm "*)  echo '{"Digest":"sha256:$D2"}' ;;
  *) exit 1 ;;
esac
SK
chmod +x "$W/bin/skopeo"

mkfix() {  # <board> <arch> <core tag> <channel> [supervisor digest in the tar name] [omit-one-addon-tar 0|1]
  local board="$1" arch="$2" ctag="$3" chan="$4" supd="${5:-$D1}" omit="${6:-0}"
  local pins img n=0 ref pre
  rm -rf "$OUTD"; mkdir -p "$OUTD/build/hassio-1.0.0/images" "$OUTD/target/usr"
  jq -n --arg a "$arch" --arg c "$ctag" --arg ch "$chan" '{channel:$ch, core:$c, supervisor:"2026.10.5.1",
     images:{supervisor:"ghcr.io/greenautarky/{arch}-hassio-supervisor", core:"ghcr.io/greenautarky/home-assistant-\($a)"}}' \
     > "$OUTD/build/hassio-1.0.0/version.json"
  img="$OUTD/build/hassio-1.0.0/images"
  touch "$img/ghcr.io_greenautarky_${arch}-hassio-supervisor_2026.10.5.1@sha256_${supd}.tar"
  pins="$ROOT/$(ga_board_var ADDON_PINS "$board")"
  for a in $(jq -r '.addons|keys[]' "$pins"); do
    n=$((n+1)); [ "$omit" = 1 ] && [ "$n" = 1 ] && continue
    ref="$(jq -r --arg n "$a" '.addons[$n]|.image+":"+.version' "$pins")"; ref="${ref//\{arch\}/$arch}"
    pre="${ref//\//_}"; pre="${pre//:/_}"
    touch "$img/${pre}@sha256_$([ "$arch" = aarch64 ] && echo "$D1" || echo "$D2").tar"
  done
}
run() {  # <board> <release>
  PATH="$W/bin:$PATH" GA_BOARD="$1" GA_RELEASE="$2" BR2EXT_NETBIRD="$ROOT/buildroot-external" \
    bash "$RUNNER" "$OUTD" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}
npins() { jq -r '.addons|length' "$ROOT/$(ga_board_var ADDON_PINS "$1")"; }
has() { printf '%s\n' "$1" | grep -qE "$2"; }

# --- DSGW-210, correct bake: green ---
mkfix dsgw210 aarch64 2026.10.4.3-dev dev
o="$(run dsgw210 BOSv1.6.0-dev5)"
has "$o" '^  PASS  BLD: Core image tag is' && ok "dsgw210: -dev Core on dev + -devN passes BLD" || bad "dsgw210: BLD not green"
has "$o" '^  PASS  VER-09: Supervisor image digest matches GHCR' && ok "dsgw210: VER-09 compares the aarch64 digest and passes" || bad "dsgw210: VER-09 not green"
has "$o" "^  PASS  VER-10: baked add-on images: $(npins dsgw210)/$(npins dsgw210) pins" && ok "dsgw210: VER-10 reads its own pin file, aarch64 tars, passes" || bad "dsgw210: VER-10 not green"
# --- DSGW-210, wrong inputs: red ---
mkfix dsgw210 aarch64 2026.10.4.3-dev stable
has "$(run dsgw210 BOSv1.6.0-dev5)" '^  FAIL  BLD: Core tag is' && ok "dsgw210: -dev Core on the stable channel FAILS" || bad "dsgw210: -dev on stable not refused"
mkfix dsgw210 aarch64 2026.10.4.3-dev dev
has "$(run dsgw210 BOSv1.6.0-rc1)" '^  FAIL  BLD: Core tag is' && ok "dsgw210: -dev Core with an rc label FAILS" || bad "dsgw210: -dev with rc label not refused"
mkfix dsgw210 aarch64 2026.10.4.3-dev dev "$D2"
has "$(run dsgw210 BOSv1.6.0-dev5)" '^  FAIL  VER-09: Supervisor STALE' && ok "dsgw210: a Supervisor tar that differs from the aarch64 digest FAILS" || bad "dsgw210: stale Supervisor not caught"
mkfix dsgw210 aarch64 2026.10.4.3-dev dev "$D1" 1
has "$(run dsgw210 BOSv1.6.0-dev5)" '^  FAIL  VER-10:' && ok "dsgw210: a pinned add-on with no tar FAILS VER-10" || bad "dsgw210: missing add-on tar not caught"
mkfix dsgw210 armv7 2026.10.4.3-dev dev
has "$(run dsgw210 BOSv1.6.0-dev5)" '^  FAIL  VER-10:' && ok "dsgw210: armv7 tarballs where aarch64 is expected FAIL VER-10" || bad "dsgw210: armv7 tars accepted"
# --- iHost: unchanged ---
mkfix ihost armv7 2026.10.4.3 stable "$D2"
o="$(run ihost BOSv1.6.0-rc2)"
has "$o" '^  PASS  BLD: Core image tag is' && ok "ihost: plain calver passes BLD" || bad "ihost: BLD not green"
has "$o" '^  PASS  VER-09: Supervisor image digest matches GHCR' && ok "ihost: VER-09 compares the armv7 digest and passes" || bad "ihost: VER-09 not green"
has "$o" "^  PASS  VER-10: baked add-on images: $(npins ihost)/$(npins ihost) pins" && ok "ihost: VER-10 reads the shared pin file, armv7 tars, passes" || bad "ihost: VER-10 not green"
mkfix ihost armv7 2026.10.4.3-dev stable "$D2"
has "$(run ihost BOSv1.6.0-rc2)" '^  FAIL  BLD: Core tag is' && ok "ihost: a -dev Core tag on the stable channel / rc label is refused" || bad "ihost: -dev Core accepted"
mkfix ihost armv7 2026.10.4.3 stable "$D1"
has "$(run ihost BOSv1.6.0-rc2)" '^  FAIL  VER-09: Supervisor STALE' && ok "ihost: a Supervisor tar that differs from the armv7 digest FAILS" || bad "ihost: stale Supervisor not caught"

[ "$ran" -ge 12 ] || { echo "FAIL: only $ran cases ran"; exit 1; }
echo "$ran cases ran, $fails failed"; exit $((fails>0))
