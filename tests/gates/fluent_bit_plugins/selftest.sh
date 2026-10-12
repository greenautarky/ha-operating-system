#!/usr/bin/env bash
# fluent_bit_plugins/selftest.sh -- every plugin a shipped fluent-bit config names
# is built into the minimal fluent-bit, and the Forward plugins are not.
#
# WHY
#   fluent-bit is built with -DFLB_MINIMAL=On plus the switches listed in
#   FLUENT_BIT_GA_PLUGINS (buildroot-external/package/fluent-bit-config/
#   fluent-bit-config.mk), so that code with an upstream advisory and no patched
#   version (the Forward output) is not in the image. The price: a plugin added
#   to a config but not to that list makes fluent-bit refuse the whole config,
#   and the unit crash-loops. This gate compares the two on every change.
#
# WHAT IT CHECKS (scripts/fluent-bit-plugin-guard.sh, the same script the build
# runs on the installed binary)
#   --configs: every config the image ships -- tier-1 and debug configs, the
#     tier-0 OS entry point, and fluent-bit-tier0.conf from ga-telemetry-config at
#     the version.yaml pin (fetched from the public repo; TIER0_OVERLAY_CONF=<file>
#     overrides offline) -- names only plugins that are in FLUENT_BIT_GA_PLUGINS.
#   --binary: the fixtures below; the real binary is checked by the build.
#
# RED/GREEN IN THE TEST ITSELF
#   must-fail/*.conf and bin-must-fail/*.txt must each be flagged, must-pass/*.conf
#   and bin-must-pass/*.txt must not. Two mutants of the LIVE list (a plugin
#   removed, the Forward output added) must each turn the live configs red --
#   that proves the guard reads the list and the configs, and not a copy.
#   The live scan fails closed: zero configs, or a guard that cannot find the
#   list, is exit 2, never green.
#
# Exit 0 = green, 1 = a verdict failed, 2 = could not check.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/tests/gates/fluent_bit_plugins"
GUARD="$ROOT/scripts/fluent-bit-plugin-guard.sh"
MK="$ROOT/buildroot-external/package/fluent-bit-config/fluent-bit-config.mk"
VERSION_YAML="$ROOT/version.yaml"

die2() { echo "ERROR (could not check): $*" >&2; exit 2; }
[ -x "$GUARD" ] || die2 "$GUARD not found or not executable"
[ -f "$MK" ] || die2 "$MK not found"
command -v strings >/dev/null || die2 "strings(1) not found (binutils)"

W="$(mktemp -d "${TMPDIR:-/tmp}/fb-plugins.XXXXXX")"
trap 'rm -rf "$W"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ok    $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

echo "fixtures (configs):"
nf=0 np=0
for f in "$HERE"/must-fail/*.conf; do
  [ -f "$f" ] || continue; nf=$((nf + 1))
  "$GUARD" --configs "$f" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && ok "must-fail $(basename "$f") flagged" || bad "must-fail $(basename "$f") rc=$rc (want 1)"
done
for f in "$HERE"/must-pass/*.conf; do
  [ -f "$f" ] || continue; np=$((np + 1))
  "$GUARD" --configs "$f" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "must-pass $(basename "$f") clean" || bad "must-pass $(basename "$f") rc=$rc (want 0)"
done
[ "$nf" -ge 1 ] && [ "$np" -ge 1 ] || die2 "config fixture dirs empty (must-fail=$nf must-pass=$np)"

echo "fixtures (binaries):"
nbf=0 nbp=0
for f in "$HERE"/bin-must-fail/*.txt; do
  [ -f "$f" ] || continue; nbf=$((nbf + 1))
  "$GUARD" --binary "$f" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && ok "must-fail $(basename "$f") flagged" || bad "must-fail $(basename "$f") rc=$rc (want 1)"
done
for f in "$HERE"/bin-must-pass/*.txt; do
  [ -f "$f" ] || continue; nbp=$((nbp + 1))
  "$GUARD" --binary "$f" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "must-pass $(basename "$f") clean" || bad "must-pass $(basename "$f") rc=$rc (want 0)"
done
[ "$nbf" -ge 1 ] && [ "$nbp" -ge 1 ] || die2 "binary fixture dirs empty (must-fail=$nbf must-pass=$nbp)"

# --- the live configs ---------------------------------------------------------
TC_VER="$(sed -n 's/^[[:space:]]*ga-telemetry-config:[[:space:]]*"\([^"]*\)".*/\1/p' "$VERSION_YAML")"
[ -n "$TC_VER" ] || die2 "no ga-telemetry-config pin in version.yaml"
if [ -n "${TIER0_OVERLAY_CONF:-}" ]; then
  cp "$TIER0_OVERLAY_CONF" "$W/fluent-bit-tier0.conf" || die2 "cannot read $TIER0_OVERLAY_CONF"
  comp_label="$TIER0_OVERLAY_CONF (override; pin is $TC_VER)"
else
  url="https://raw.githubusercontent.com/greenautarky/ga-telemetry-config/v${TC_VER}/src/ga-telemetry-config/etc/fluent-bit/fluent-bit-tier0.conf"
  curl -fsS --retry 3 --max-time 30 -o "$W/fluent-bit-tier0.conf" "$url" || die2 "cannot fetch $url"
  comp_label="ga-telemetry-config v$TC_VER"
fi
mapfile -t live < <(
  find "$ROOT"/buildroot-*/rootfs-overlay/etc/fluent-bit "$ROOT/buildroot-external/package/fluent-bit-config" \
    -name '*.conf' -type f ! -name parsers.conf 2>/dev/null | sort
)
[ "${#live[@]}" -ge 1 ] || die2 "no fluent-bit configs found in the tree"

echo "live (component: $comp_label; ${#live[@]} configs in this tree + the component's):"
out="$("$GUARD" --configs "${live[@]}" "$W/fluent-bit-tier0.conf" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "live configs name only built plugins -- $(printf '%s\n' "$out" | head -1)"
else bad "live configs (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/        /'; fi
[ "$rc" -ne 2 ] || die2 "the guard could not check the live configs"

echo "mutants of the live list (each must turn the live configs red):"
sed 's/ FLB_FILTER_MODIFY / /; s/^\tFLB_FILTER_GREP FLB_FILTER_RECORD_MODIFIER FLB_FILTER_MODIFY \\$/\tFLB_FILTER_GREP FLB_FILTER_RECORD_MODIFIER \\/' "$MK" > "$W/mk-no-modify"
if cmp -s "$MK" "$W/mk-no-modify"; then bad "mutant 'modify removed' equals the live .mk (sed pattern stale)"
else
  "$GUARD" --mk "$W/mk-no-modify" --configs "${live[@]}" "$W/fluent-bit-tier0.conf" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && ok "list without filter_modify: live configs flagged" || bad "list without filter_modify: rc=$rc (want 1)"
fi
sed 's/^\tFLB_OUT_LOKI$/\tFLB_OUT_LOKI FLB_OUT_FORWARD/' "$MK" > "$W/mk-forward"
if cmp -s "$MK" "$W/mk-forward"; then bad "mutant 'forward added' equals the live .mk (sed pattern stale)"
else
  "$GUARD" --mk "$W/mk-forward" --configs "${live[@]}" "$W/fluent-bit-tier0.conf" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && ok "list with the Forward output: flagged" || bad "list with the Forward output: rc=$rc (want 1)"
fi
printf 'nothing here\n' > "$W/mk-empty"
"$GUARD" --mk "$W/mk-empty" --configs "${live[@]}" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "no list in the .mk: exit 2 (cannot check), not green" || bad "no list in the .mk: rc=$rc (want 2)"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] && { echo "PASS: every plugin the shipped fluent-bit configs name is built, the Forward plugins are not"; exit 0; }
exit 1
