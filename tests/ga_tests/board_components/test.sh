#!/usr/bin/env bash
# board_components — per-board Tier-2 components (components_<board>:, Odoo #2187).
#
# A board component is staged ONLY into that board's own overlay, so no other
# board's image carries it. ga_dsgw_ble is the first: it declares the `bluetooth`
# dependency, which on the iHost would start HA's own Bluetooth integration.
#
# Everything here runs the LIVE code — scripts/sync-components.sh,
# scripts/lib/ga-components.sh (pre-flight + image check) and the live board map
# scripts/lib/tree-paths.sh — against a fixture repo in a temp dir. Artifacts come
# from local tarballs (GA_SYNC_FROM_DIR) instead of `oras pull`; placement is the
# subject, the registry is not.
#
#   rows that must stay green: BCT-01..03, 06, 08, 11a/b; rows that must flag: BCT-04, 05, 07, 09, 10, 11c/d
#
# Needs yq for the shared block (sync's existing reader; CI runners carry it).
# Without yq the sync rows FAIL in CI and SKIP loudly elsewhere — never silently.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SYNC="$ROOT/scripts/sync-components.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0; skip=0
PASS() { echo "  PASS  $1"; pass=$((pass+1)); }
FAIL() { echo "  FAIL  $1${2:+ ($2)}"; fail=$((fail+1)); }
SKIP() { echo "  SKIP  $1 ($2)"; skip=$((skip+1)); }
ok()   { if eval "$2"; then PASS "$1"; else FAIL "$1" "$3"; fi; }

echo ""; echo "=== board_components: components_<board>: staged on that board only ==="
for f in "$SYNC" "$ROOT/scripts/lib/ga-components.sh" "$ROOT/scripts/lib/tree-paths.sh"; do
  [ -r "$f" ] || { echo "FATAL: input missing: $f"; exit 1; }
done
# shellcheck source=../../../scripts/lib/tree-paths.sh
. "$ROOT/scripts/lib/tree-paths.sh"
# shellcheck source=../../../scripts/lib/ga-components.sh
. "$ROOT/scripts/lib/ga-components.sh"

DSGW_BASE="$(ga_board_var BOARD_BASE dsgw210)"; IHOST_BASE="$(ga_board_var BOARD_BASE ihost)"
[ -n "$DSGW_BASE" ] && [ -n "$IHOST_BASE" ] || { echo "FATAL: board map has no dsgw210/ihost"; exit 1; }

# --- fixtures -----------------------------------------------------------------
ART="$W/artifacts"; mkdir -p "$ART"
mkart() {  # <pkg-name> <version>
  _d="$W/build/$(echo "$1" | tr '-' '_')"; mkdir -p "$_d"
  printf '{"domain":"%s","version":"%s"}\n' "$(echo "$1" | tr '-' '_')" "$2" > "$_d/manifest.json"
  tar -czf "$ART/$1-$2.tar.gz" -C "$W/build" "$(basename "$_d")"; rm -rf "$W/build"
}
mkart shared-comp 1.0.0; mkart ga-dsgw-ble 0.1.0
newrepo() {  # <name> <version.yaml body> -> path
  _r="$W/$1"; mkdir -p "$_r/$GA_LAYER_DIR/rootfs-overlay/usr/share/ga/custom_components" \
    "$_r/$DSGW_BASE/rootfs-overlay" "$_r/$IHOST_BASE"
  printf '%s\n' "$2" > "$_r/version.yaml"; echo "$_r"
}
sync_in() {  # <repo> -> rc; output in $W/sync.out
  GA_SYNC_REPO_ROOT="$1" GA_SYNC_FROM_DIR="$ART" bash "$SYNC" > "$W/sync.out" 2>&1
}
GOOD_YAML='# fixture
components:
  shared-comp: "1.0.0"   # a comment: with a colon and "quotes"

components_dsgw210:
  ga-dsgw-ble: "0.1.0"   # DSGW only

rootfs_overlays: {}'
cc() { echo "$1/usr/share/ga/custom_components"; }

# --- the reader -----------------------------------------------------------------
ok "BCT-01 reader: the shared block of the LIVE version.yaml reads non-empty" \
   '[ -n "$(ga_components_block "$ROOT/version.yaml" components)" ]' "empty shared block"
R0=$(newrepo reader "$GOOD_YAML")
ok "BCT-02 reader: fixture blocks (comments, quotes) read as pinned" \
   '[ "$(ga_components_block "$R0/version.yaml" components)" = "shared-comp 1.0.0" ] && [ "$(ga_components_block "$R0/version.yaml" components_dsgw210)" = "ga-dsgw-ble 0.1.0" ] && [ "$(ga_component_boards "$R0/version.yaml")" = dsgw210 ]' \
   "shared='$(ga_components_block "$R0/version.yaml" components)' board='$(ga_components_block "$R0/version.yaml" components_dsgw210)'"

# --- sync -------------------------------------------------------------------------
if ! command -v yq >/dev/null 2>&1; then
  if [ "${GITHUB_ACTIONS:-}" = true ]; then FAIL "BCT-03..07 sync rows" "yq missing on a CI runner"
  else SKIP "BCT-03..07 sync rows" "yq not installed here; CI runs them"; fi
else
  R1=$(newrepo good "$GOOD_YAML"); sync_in "$R1"; rc=$?
  ok "BCT-03 sync (must-pass): shared comp in the shared overlay, ga_dsgw_ble ONLY in the DSGW overlay" \
     '[ $rc -eq 0 ] && [ -f "$(cc "$R1/$GA_LAYER_DIR/rootfs-overlay")/shared_comp/manifest.json" ] && [ -f "$(cc "$R1/$DSGW_BASE/rootfs-overlay")/ga_dsgw_ble/manifest.json" ] && [ ! -e "$(cc "$R1/$GA_LAYER_DIR/rootfs-overlay")/ga_dsgw_ble" ]' \
     "rc=$rc: $(tail -3 "$W/sync.out" | tr '\n' ' ')"

  R2=$(newrepo both "$(printf '%s\n' "$GOOD_YAML" | sed 's/^  shared-comp:.*/  ga-dsgw-ble: "0.1.0"/')"); sync_in "$R2"; rc=$?
  ok "BCT-04 sync (must-fail): the same component in components: AND components_dsgw210: -> exit 4" \
     '[ $rc -eq 4 ] && grep -q "one or the other" "$W/sync.out"' "rc=$rc: $(tail -2 "$W/sync.out" | tr '\n' ' ')"

  R3=$(newrepo ihostblock "$(printf '%s\n' "$GOOD_YAML" | sed 's/^components_dsgw210:/components_ihost:/')"); sync_in "$R3"; rc=$?
  ok "BCT-05 sync (must-fail): a board without its own overlay (ihost) -> exit 4, nothing in the shared overlay" \
     '[ $rc -eq 4 ] && grep -q "no own rootfs overlay" "$W/sync.out" && [ ! -e "$(cc "$R3/$GA_LAYER_DIR/rootfs-overlay")/ga_dsgw_ble" ]' \
     "rc=$rc: $(tail -2 "$W/sync.out" | tr '\n' ' ')"

  R4=$(newrepo stale "$GOOD_YAML"); mkdir -p "$(cc "$R4/$GA_LAYER_DIR/rootfs-overlay")/ga_dsgw_ble"
  sync_in "$R4"; rc=$?
  ok "BCT-06 sync (must-pass): a stale board component in the SHARED overlay is removed, loudly" \
     '[ $rc -eq 0 ] && [ ! -e "$(cc "$R4/$GA_LAYER_DIR/rootfs-overlay")/ga_dsgw_ble" ] && grep -q "must not be in the shared overlay" "$W/sync.out"' \
     "rc=$rc"

  # Flow style is valid YAML: yq reads the pin, the line reader ga_build.sh uses
  # does not. Two readers of one truth must be compared, never trusted.
  R5=$(newrepo drift "components: {shared-comp: \"1.0.0\"}"); sync_in "$R5"; rc=$?
  ok "BCT-07 sync (must-fail): yq and the ga_build reader disagree (flow mapping) -> exit 5" \
     '[ $rc -eq 5 ] && grep -q "reads differently" "$W/sync.out"' "rc=$rc: $(tail -2 "$W/sync.out" | tr '\n' ' ')"
fi

# --- ga_build pre-flight ------------------------------------------------------------
P1=$(newrepo pf "$GOOD_YAML"); mkdir -p "$(cc "$P1/$DSGW_BASE/rootfs-overlay")/ga_dsgw_ble"
printf '{"domain":"ga_dsgw_ble","version":"0.1.0"}\n' > "$(cc "$P1/$DSGW_BASE/rootfs-overlay")/ga_dsgw_ble/manifest.json"
ok "BCT-08 pre-flight (must-pass): DSGW build with the pin synced; iHost build with nothing to check" \
   'ga_board_components_preflight "$P1" dsgw210 >/dev/null 2>&1 && ga_board_components_preflight "$P1" ihost >/dev/null 2>&1' \
   "$(ga_board_components_preflight "$P1" dsgw210 2>&1 | tail -1)"
P2=$(newrepo pfbad "$GOOD_YAML"); mkdir -p "$(cc "$P2/$GA_LAYER_DIR/rootfs-overlay")/ga_dsgw_ble"
ok "BCT-09 pre-flight (must-fail): ga_dsgw_ble in the SHARED overlay fails the iHost build" \
   '! ga_board_components_preflight "$P2" ihost >/dev/null 2>&1 && ga_board_components_preflight "$P2" ihost 2>&1 | grep -q "is in the SHARED overlay"' "did not flag"
P3=$(newrepo pfver "$GOOD_YAML"); mkdir -p "$(cc "$P3/$DSGW_BASE/rootfs-overlay")/ga_dsgw_ble"
printf '{"domain":"ga_dsgw_ble","version":"0.0.9"}\n' > "$(cc "$P3/$DSGW_BASE/rootfs-overlay")/ga_dsgw_ble/manifest.json"
ok "BCT-10 pre-flight (must-fail): DSGW overlay holds 0.0.9 but 0.1.0 is pinned" \
   'ga_board_components_preflight "$P3" dsgw210 2>&1 | grep -q "manifest says 0.0.9"' "did not flag"

# --- image check (run_build_tests BLD-BC) ---------------------------------------------
T_DSGW="$W/t-dsgw"; T_IH="$W/t-ihost"; T_IH_BAD="$W/t-ihost-bad"; T_DSGW_BAD="$W/t-dsgw-bad"
for t in "$T_DSGW" "$T_IH" "$T_IH_BAD" "$T_DSGW_BAD"; do mkdir -p "$(cc "$t")/shared_comp"; done
for t in "$T_DSGW" "$T_IH_BAD"; do mkdir -p "$(cc "$t")/ga_dsgw_ble"; printf '{"version":"0.1.0"}\n' > "$(cc "$t")/ga_dsgw_ble/manifest.json"; done
ok "BCT-11a image (must-pass): the DSGW image carries ga_dsgw_ble@0.1.0" \
   'ga_board_components_image_check "$R0/version.yaml" "$T_DSGW" dsgw210 | grep -q "PASS BCI-01 dsgw210 image carries ga_dsgw_ble@0.1.0"' "$(ga_board_components_image_check "$R0/version.yaml" "$T_DSGW" dsgw210)"
ok "BCT-11b image (must-pass): the iHost image does NOT carry ga_dsgw_ble" \
   'ga_board_components_image_check "$R0/version.yaml" "$T_IH" ihost | grep -q "PASS BCI-02 ihost image does not carry ga_dsgw_ble"' "$(ga_board_components_image_check "$R0/version.yaml" "$T_IH" ihost)"
ok "BCT-11c image (must-fail): an iHost image WITH ga_dsgw_ble is flagged BCI-02" \
   '! ga_board_components_image_check "$R0/version.yaml" "$T_IH_BAD" ihost >/dev/null && ga_board_components_image_check "$R0/version.yaml" "$T_IH_BAD" ihost | grep -q "FAIL BCI-02"' "not flagged"
ok "BCT-11d image (must-fail): a DSGW image WITHOUT ga_dsgw_ble is flagged BCI-01" \
   '! ga_board_components_image_check "$R0/version.yaml" "$T_DSGW_BAD" dsgw210 >/dev/null && ga_board_components_image_check "$R0/version.yaml" "$T_DSGW_BAD" dsgw210 | grep -q "FAIL BCI-01"' "not flagged"

echo ""
echo "board_components: $pass passed, $fail failed, $skip skipped"
echo "{\"suite\":\"board_components\",\"pass\":$pass,\"fail\":$fail,\"skip\":$skip}"
[ "$fail" -eq 0 ] && [ "$pass" -ge 8 ]
