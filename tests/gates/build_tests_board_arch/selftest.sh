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
# curl stand-in for the version channel files (stable.json = the old iHost line, rc.json = what an -rcN of the 1.6
# line bakes from (#1610), dev.json = the 1.6 dev line)
cat > "$W/bin/curl" <<'CU'
#!/bin/bash
case "$*" in
  *stable.json*) echo '{"core":"2026.8.2.2","supervisor":"2025.11.5.10","homeassistant":{"tinker":"2026.8.2.2"},"images":{"core":"ghcr.io/greenautarky/home-assistant-armv7","supervisor":"x"}}' ;;
  *rc.json*)     echo '{"core":"2026.8.2.2","supervisor":"2026.10.5.1","homeassistant":{"tinker":"2026.8.2.2"},"images":{"core":"ghcr.io/greenautarky/home-assistant-armv7","supervisor":"x"}}' ;;
  *dev.json*)    echo '{"core":"2026.10.4.3-dev","supervisor":"2026.10.5.1","homeassistant":{"tinker":"2026.10.4.3-dev"},"images":{"core":"'"${STUB_DEV_CORE_IMG:-ghcr.io/greenautarky/home-assistant-aarch64}"'","supervisor":"x"}}' ;;
  *) exit 22 ;;
esac
CU
chmod +x "$W/bin/curl"

mkfix() {  # <board> <arch> <core tag> <channel> [supervisor digest in the tar name] [omit-one-addon-tar 0|1]
  local board="$1" arch="$2" ctag="$3" chan="$4" supd="${5:-$D1}" omit="${6:-0}"
  local pins img n=0 ref pre
  rm -rf "$OUTD"; mkdir -p "$OUTD/build/hassio-1.0.0/images" "$OUTD/target/usr"
  jq -n --arg a "$arch" --arg c "$ctag" --arg ch "$chan" --arg sv "${SUPV:-2026.10.5.1}" '{channel:$ch, core:$c, supervisor:$sv,
     images:{supervisor:"ghcr.io/greenautarky/{arch}-hassio-supervisor", core:"ghcr.io/greenautarky/home-assistant-\($a)"}}' \
     > "$OUTD/build/hassio-1.0.0/version.json"
  img="$OUTD/build/hassio-1.0.0/images"
  touch "$img/ghcr.io_greenautarky_${arch}-hassio-supervisor_${SUPV:-2026.10.5.1}@sha256_${supd}.tar"
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

# --- XVER-06/07: the build is compared against ITS OWN channel file ---
mkfix dsgw210 aarch64 2026.10.4.3-dev dev
o="$(run dsgw210 BOSv1.6.0-dev5)"
has "$o" '^  PASS  XVER-06: .*matches dev.json' && ok "dsgw210: XVER-06 compares against dev.json and passes" || bad "dsgw210: XVER-06 not green"
has "$o" '^  PASS  XVER-07: .*matches dev.json' && ok "dsgw210: XVER-07 compares against dev.json and passes" || bad "dsgw210: XVER-07 not green"
has "$o" '^  PASS  XVER-03: dev.json core image is the GA aarch64 build' && ok "dsgw210: XVER-03 expects the aarch64 Core image and passes" || bad "dsgw210: XVER-03 not green"
o="$(STUB_DEV_CORE_IMG=ghcr.io/greenautarky/home-assistant-armv7 run dsgw210 BOSv1.6.0-dev5)"
has "$o" '^  FAIL  XVER-03: dev.json core image is NOT the GA aarch64 build' && ok "dsgw210: an armv7 Core image in dev.json FAILS XVER-03" || bad "dsgw210: armv7 Core image in dev.json accepted"
SUPV=2026.10.4.0 mkfix dsgw210 aarch64 2026.10.4.3-dev dev
o="$(SUPV=2026.10.4.0 run dsgw210 BOSv1.6.0-dev5)"
has "$o" '^  FAIL  XVER-07: .*dev.json' && ok "dsgw210: a Supervisor that differs from dev.json FAILS XVER-07" || bad "dsgw210: XVER-07 drift not caught"
mkfix ihost armv7 2026.8.2.2 stable "$D2"
# an -rcN of the 1.6 line bakes from rc.json (#1610): XVER-06/07 compare against rc.json
o="$(run ihost BOSv1.6.0-rc2)"
has "$o" '^  PASS  XVER-07: .*matches rc.json' && ok "ihost rc label: XVER-07 compares against rc.json and passes" || bad "ihost rc label: XVER-07 not against rc.json"
has "$o" '^  PASS  XVER-06: .*matches rc.json' && ok "ihost rc label: XVER-06 compares against rc.json and passes" || bad "ihost rc label: XVER-06 not against rc.json"
# a final label still bakes from stable.json: the same build is then compared against stable
o="$(run ihost BOSv1.6.0)"
has "$o" '^  FAIL  XVER-07: .*stable.json' && ok "ihost final label: compared against stable.json (Supervisor 2026.10.5.1 != stable)" || bad "ihost final label: XVER-07 not against stable.json"
has "$o" '^  PASS  XVER-06: .*matches stable.json' && ok "ihost final label: XVER-06 matches stable.json" || bad "ihost final label: XVER-06 not against stable.json"
o="$(run ihost BOSv1.6.0-rc2)"
has "$o" '^  PASS  XVER-03: stable.json core image is the GA armv7 build' && ok "ihost: XVER-03 still expects the armv7 Core image" || bad "ihost: XVER-03 not green"

# WIFI-09 needs /usr/sbin/iw (shared overlay: ga-wifi-watchdog, ga-wlan0-powersave-assert): every board's
# defconfig must build it in (the DSGW-210 did not: BOSv1.6.0-dev4 re-bake, run 42233089444)
for b in $GA_BOARDS; do
  grep -qx 'BR2_PACKAGE_IW=y' "$ROOT/$(ga_board_var DEFCONFIG "$b")" && ok "$b: defconfig builds iw in" || bad "$b: defconfig lacks BR2_PACKAGE_IW=y"
done
[ "$ran" -ge 21 ] || { echo "FAIL: only $ran cases ran"; exit 1; }
echo "$ran cases ran, $fails failed"; exit $((fails>0))
