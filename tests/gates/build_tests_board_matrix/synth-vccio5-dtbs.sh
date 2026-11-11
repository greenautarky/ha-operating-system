#!/bin/bash
# synth-vccio5-dtbs.sh OUT BOARD -- give an iHost fixture build output the vccio5 = 3.3 V DTB variants
# (Odoo #1900) the way the image build does: the LIVE generator
# buildroot-ihost/board/sonoff/ihost/make-vccio5-3v3-dtb.sh run on the fixture's OWN real DTBs
# (images/boot/rv11{26,09}-sonoff-ihost.dtb, captured from the BOSv1.6.0-rc3 bake, which predates #1900).
# It also provides OUT/host/bin/fdtget, which BLD-VCC-01 reads with (the bake ships host-dtc there).
# So BLD-VCC-01 is judged by its REAL code on real DTBs, not parked in NOT_COVERED.
# Other boards: nothing to do (BLD-VCC-01 is iHost-only).
# Mutations for the red proofs (env, default off):
#   SYNTH_VCC_NO_RV1109=1  the rv1109 variant is not produced          -> BLD-VCC-01 must FAIL
#   SYNTH_VCC_1V8=1        the rv1126 "variant" is the 1.8 V base copy -> BLD-VCC-01 must FAIL
# Fails (exit 2, never skips) when the tools or the fixture DTBs are missing.
set -eu
OUT="${1:?OUT}"; BOARD="${2:?board}"
[ "$BOARD" = ihost ] || exit 0
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
GEN="$ROOT/buildroot-ihost/board/sonoff/ihost/make-vccio5-3v3-dtb.sh"
[ -r "$GEN" ] || { echo "synth-vccio5: generator $GEN missing" >&2; exit 2; }
for t in fdtget fdtput dtc; do command -v "$t" >/dev/null || { echo "synth-vccio5: $t missing (install device-tree-compiler)" >&2; exit 2; }; done
B="$OUT/images/boot"
mkdir -p "$OUT/host/bin"; ln -sf "$(command -v fdtget)" "$OUT/host/bin/fdtget"
for soc in rv1126 rv1109; do
  [ -f "$B/$soc-sonoff-ihost.dtb" ] || { echo "synth-vccio5: fixture has no $B/$soc-sonoff-ihost.dtb" >&2; exit 2; }
  [ "$soc" = rv1109 ] && [ -n "${SYNTH_VCC_NO_RV1109:-}" ] && continue
  if [ "$soc" = rv1126 ] && [ -n "${SYNTH_VCC_1V8:-}" ]; then
    cp "$B/$soc-sonoff-ihost.dtb" "$B/$soc-sonoff-ihost-vccio5-3v3.dtb"; continue
  fi
  bash "$GEN" "$B/$soc-sonoff-ihost.dtb" "$B/$soc-sonoff-ihost-vccio5-3v3.dtb" >/dev/null \
    || { echo "synth-vccio5: the generator refused the fixture's $soc DTB" >&2; exit 2; }
done
