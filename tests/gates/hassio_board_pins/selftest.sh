#!/usr/bin/env bash
# hassio.mk (upstream + patches 0131/0133) validates version.json at configure
# time against pins. The iHost pins live in version.yaml; a board with its own
# GA Supervisor/Core (DSGW-210) declares GA_HASSIO_SUPERVISOR_PIN/_CORE_PIN in
# its external.mk. This runs the LIVE HASSIO_CONFIGURE_CMDS (hassio.mk as the
# build sees it, via apply-haos-patches.sh --cat; the real check-core-image.sh and
# check-supervisor-image.sh linked in, never copies) against fixture channel files:
#   must-pass: DSGW dev with board pins; iHost stable with no board pins (unchanged)
#   must-fail: DSGW dev WITHOUT the board pins (version.yaml's iHost pins apply),
#              channel Supervisor off the board pin, channel Core off the board
#              pin, only one of the two pins set, a -dev Core on the stable
#              channel
# Each must-fail names the text it must produce, so the rule under test is the one
# that fired. Zero cases = FAIL. Needs haos/ (CI gate-selftest has it); HAOS_DIR overrides.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
EXT="$ROOT/buildroot-external"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
"$ROOT/scripts/apply-haos-patches.sh" --cat buildroot-external/package/hassio/hassio.mk > "$tmp/hassio.mk" 2>"$tmp/cat.err" \
  || { echo "FAIL: cannot read hassio.mk as the build sees it:"; cat "$tmp/cat.err"; exit 1; }
grep -q '^HASSIO_VERSION_URL' "$tmp/hassio.mk" && grep -q 'GA_HASSIO_SUPERVISOR_PIN' "$tmp/hassio.mk" \
  || { echo "FAIL: hassio.mk lacks HASSIO_VERSION_URL or the board pins (patch 0133 missing?)"; exit 1; }

# make harness: just enough of buildroot for hassio.mk to evaluate; the recipe under test is real.
cat > "$tmp/Makefile" <<'MK'
qstrip = $(strip $(subst ",,$(1)))
generic-package =
BR2_EXTERNAL_HAOS_PATH = $(EXT)
BR2_EXTERNAL_GA_HAOS_PATH = $(EXT)
include $(MKFILE)
-include $(BOARDMK)
run:
	$(HASSIO_CONFIGURE_CMDS)
MK

mkext() { # dir: ext/package/hassio linked to the LIVE gates, version.yaml beside ext
  local d="$1"; mkdir -p "$d/ext/package/hassio"
  ln -s "$EXT/package/hassio/check-core-image.sh" "$d/ext/package/hassio/"
  ln -s "$EXT/package/hassio/check-supervisor-image.sh" "$d/ext/package/hassio/"
  ln -s "$EXT/package/hassio/bake-source-file.sh" "$d/ext/package/hassio/"   # patch 0134: hassio.mk asks it which haos-version file to bake
  printf 'x:\n  homeassistant_core:        "2026.8.2"  # ihost\n  homeassistant_supervisor:  "2025.11.5.10"  # ihost\n' > "$d/version.yaml"
}
chan() { # dir channel supervisor core coreimg ; DSGW-shaped (qemuarm-64)
  mkdir -p "$1/c"; printf '{"channel":"%s","supervisor":"%s","homeassistant":{"default":"%s","qemuarm-64":"%s"},"images":{"core":"%s","supervisor":"ghcr.io/greenautarky/{arch}-hassio-supervisor"},"core":"%s"}\n' "$2" "$3" "$4" "$4" "$5" "$4" > "$1/c/$2.json"
}
sup_cfg() { printf '{"config":{"Labels":{"io.hass.version":"%s","io.hass.type":"supervisor","io.hass.arch":"%s"}}}\n' "$2" "$3" > "$1"; }
CORE_A64='ghcr.io/greenautarky/home-assistant-aarch64'
core_cfg_a64() { printf '{"architecture":"arm64","config":{"Labels":{"io.hass.arch":"aarch64","io.hass.type":"core","io.hass.machine":"qemuarm-64","io.hass.version":"%s"},"Entrypoint":["/init"]}}\n' "$1" > "$2"; }

bad=0 n=0
run_case() { # label want(pass|fail) wanttext dir arch machine channel boardmk
  local label="$1" want="$2" text="$3" d="$4" arch="$5" machine="$6" chn="$7" bmk="$8" out rc
  n=$((n+1)); printf '%s\n' "$bmk" > "$d/board.mk"
  local chvar; chvar="BR2_PACKAGE_HASSIO_CHANNEL_$(tr a-z A-Z <<<"$chn")=y"
  out="$(cd "$d" && make -s -f "$tmp/Makefile" run EXT="$d/ext" MKFILE="$tmp/hassio.mk" BOARDMK="$d/board.mk" \
        HASSIO_VERSION_URL="file://$d/c/" BR2_PACKAGE_HASSIO_ARCH="$arch" BR2_PACKAGE_HASSIO_MACHINE="$machine" \
        BR2_PACKAGE_HASSIO_FULL_CORE=y "$chvar" \
        CORE_IMAGE_CONFIG_FILE="$d/core.json" SUPERVISOR_IMAGE_CONFIG_FILE="$d/sup.json" 2>&1)"; rc=$?
  if [ "$want" = pass ] && [ "$rc" -eq 0 ] && grep -qF -- "$text" <<<"$out"; then echo "  ok    must-pass: $label"
  elif [ "$want" = fail ] && [ "$rc" -ne 0 ] && grep -qF -- "$text" <<<"$out"; then echo "  ok    must-fail: $label"
  else echo "  FAIL  $label (want $want, rc=$rc, text [$text])"; echo "$out" | sed 's/^/        /' | tail -12; bad=1; fi
}
BOARD_PINS='GA_HASSIO_SUPERVISOR_PIN = 2026.10.5.1
GA_HASSIO_CORE_PIN = 2026.10.4.3-dev'
mkcase() { local d="$tmp/$1"; mkext "$d"; echo "$d"; }

d=$(mkcase dsgw-ok); chan "$d" dev 2026.10.5.1 2026.10.4.3-dev $CORE_A64; sup_cfg "$d/sup.json" 2026.10.5.1 aarch64; core_cfg_a64 2026.10.4.3-dev "$d/core.json"
run_case "DSGW dev with the board pins" pass "version.json validated: supervisor=2026.10.5.1 core=2026.10.4.3-dev" "$d" aarch64 qemuarm-64 dev "$BOARD_PINS"
run_case "DSGW dev WITHOUT board pins: the iHost version.yaml pins apply" fail "is '2025.11.5.10'" "$d" aarch64 qemuarm-64 dev ""
run_case "only the Supervisor pin set" fail "must be set together" "$d" aarch64 qemuarm-64 dev "GA_HASSIO_SUPERVISOR_PIN = 2026.10.5.1"
run_case "only the Core pin set" fail "must be set together" "$d" aarch64 qemuarm-64 dev "GA_HASSIO_CORE_PIN = 2026.10.4.3-dev"

d=$(mkcase sup-off); chan "$d" dev 2026.10.5.2 2026.10.4.3-dev $CORE_A64; sup_cfg "$d/sup.json" 2026.10.5.2 aarch64; core_cfg_a64 2026.10.4.3-dev "$d/core.json"
run_case "channel Supervisor differs from the board pin" fail "supervisor='2026.10.5.2' but the pin" "$d" aarch64 qemuarm-64 dev "$BOARD_PINS"

d=$(mkcase core-off); chan "$d" dev 2026.10.5.1 2026.10.4.4-dev $CORE_A64; sup_cfg "$d/sup.json" 2026.10.5.1 aarch64; core_cfg_a64 2026.10.4.4-dev "$d/core.json"
run_case "channel Core differs from the board pin" fail "core='2026.10.4.4-dev' but the pin" "$d" aarch64 qemuarm-64 dev "$BOARD_PINS"

d=$(mkcase dev-core-stable); chan "$d" stable 2026.10.5.1 2026.10.4.3-dev $CORE_A64; sup_cfg "$d/sup.json" 2026.10.5.1 aarch64; core_cfg_a64 2026.10.4.3-dev "$d/core.json"
run_case "a -dev Core on the stable channel" fail "carries -dev but the channel is" "$d" aarch64 qemuarm-64 stable "$BOARD_PINS"

d=$(mkcase ihost-ok); mkdir -p "$d/c"
printf '{"channel":"stable","supervisor":"2025.11.5.10","homeassistant":{"default":"2026.8.2","tinker":"2026.8.2"},"images":{"core":"ghcr.io/greenautarky/home-assistant-armv7","supervisor":"ghcr.io/greenautarky/{arch}-hassio-supervisor"},"core":"2026.8.2"}\n' > "$d/c/stable.json"
sup_cfg "$d/sup.json" 2025.11.5.10 armv7; cp "$ROOT/tests/gates/core_image/must-pass/ga-t3-2026.8.2/config.json" "$d/core.json"
run_case "iHost stable, no board pins (unchanged)" pass "version.json validated: supervisor=2025.11.5.10 core=2026.8.2" "$d" armv7 tinker stable ""

# --- the REAL DSGW-210 board files (data under audit; the rule is defined here) ----
# #1186: a Core >= 2026.9 needs a Supervisor >= 2026.10 (2026.9 removed the token the
# 2025.11 Supervisor logs in with). The board pins and the defconfig must agree on it.
pin_of() { sed -n "s/^$1[[:space:]]*=[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$2" | head -n 1; }
pair_verdict() { # <external.mk> <defconfig> -> "ok" | reason
  local sup core cy cm sy sm
  sup="$(pin_of GA_HASSIO_SUPERVISOR_PIN "$1")"; core="$(pin_of GA_HASSIO_CORE_PIN "$1")"
  [ -n "$sup" ] && [ -n "$core" ] || { echo "board pins missing"; return; }
  grep -q '^BR2_PACKAGE_HASSIO_FULL_CORE=y$' "$2" || { echo "defconfig lacks FULL_CORE=y"; return; }
  grep -q '^BR2_PACKAGE_HASSIO_CHANNEL_DEV=y$' "$2" || { echo "defconfig is not the dev channel"; return; }
  IFS=. read -r cy cm _ <<<"$core"; IFS=. read -r sy sm _ <<<"$sup"
  if (( cy > 2026 || (cy == 2026 && cm >= 9) )) && ! (( sy > 2026 || (sy == 2026 && sm >= 10) )); then
    echo "Core $core with Supervisor $sup (#1186: Core 2026.9+ needs Supervisor 2026.10+)"; return; fi
  echo ok
}
pair_case() { # label want(ok|bad) <external.mk> <defconfig>
  n=$((n+1)); local v; v="$(pair_verdict "$3" "$4")"
  if { [ "$2" = ok ] && [ "$v" = ok ]; } || { [ "$2" = bad ] && [ "$v" != ok ]; }; then echo "  ok    pair: $1 [$v]"
  else echo "  FAIL  pair: $1 (want $2, got [$v])"; bad=1; fi
}
BOARD="$(. "$ROOT/scripts/lib/tree-paths.sh"; ga_board_var BOARD_DIR dsgw210)"
DEFC="$(. "$ROOT/scripts/lib/tree-paths.sh"; ga_board_var DEFCONFIG dsgw210)"
[ -r "$ROOT/$BOARD/external.mk" ] && [ -r "$ROOT/$DEFC" ] || { echo "FAIL: DSGW board files not found"; exit 1; }
pair_case "REAL DSGW-210 board pins + defconfig" ok "$ROOT/$BOARD/external.mk" "$ROOT/$DEFC"
mkdir -p "$tmp/pair"
printf 'GA_HASSIO_SUPERVISOR_PIN = 2025.11.5.10\nGA_HASSIO_CORE_PIN = 2026.10.4.3-dev\n' > "$tmp/pair/old-sup.mk"
printf 'GA_HASSIO_CORE_PIN = 2026.10.4.3-dev\n' > "$tmp/pair/no-sup.mk"
printf 'BR2_PACKAGE_HASSIO_CHANNEL_STABLE=y\nBR2_PACKAGE_HASSIO_FULL_CORE=y\n' > "$tmp/pair/stable.defconfig"
printf 'BR2_PACKAGE_HASSIO_CHANNEL_DEV=y\n' > "$tmp/pair/nocore.defconfig"
pair_case "Core 2026.10 with the 2025.11 Supervisor"  bad "$tmp/pair/old-sup.mk" "$ROOT/$DEFC"
pair_case "Supervisor pin missing"                    bad "$tmp/pair/no-sup.mk"  "$ROOT/$DEFC"
pair_case "defconfig on the stable channel"           bad "$ROOT/$BOARD/external.mk" "$tmp/pair/stable.defconfig"
pair_case "defconfig without FULL_CORE"               bad "$ROOT/$BOARD/external.mk" "$tmp/pair/nocore.defconfig"

[ "$n" -ge 13 ] || { echo "FAIL: only $n cases ran (want >= 13)"; exit 1; }
echo "$n cases ran"; exit "$bad"
