#!/bin/bash
# build_board_skips — holds tests/ga_tests/build_board_skips.tsv to run_build_tests.sh.
#
# The table turns a FAIL into a SKIP for one board, with a stated reason. That is
# a power to hide failures, so it is checked here, on the LIVE table and the LIVE
# runner (no copy of either):
#   1. every row is well formed: known board, known condition, a reason;
#   2. every row's glob matches a failure message the runner can actually emit
#      (a typo would silently skip nothing, or a renamed check would orphan a row);
#   3. every condition is TRUE for its board (core-skipped: the board's external.mk
#      says so; no-addons: it names no add-on list), so a reason cannot go stale;
#   4. the runner, on a fixture, skips a listed check on its board with the reason
#      and does NOT skip it on the iHost, does not skip an unlisted check, and
#      skips nothing when the table is missing a reason or uses an unknown
#      condition (fail closed).
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TABLE="$ROOT/tests/ga_tests/build_board_skips.tsv"
RUNNER="$ROOT/tests/ga_tests/run_build_tests.sh"
# shellcheck source=../../../scripts/lib/tree-paths.sh
. "$ROOT/scripts/lib/tree-paths.sh"
W="$(mktemp -d -t bbs-XXXXXX)"
# The runner finds the source tree as the PARENT of the output dir, so the fixture
# output sits in the checkout (ga_output*/ is git-ignored).
OUTD="$ROOT/ga_output-bbs-fixture.$$"
trap 'rm -rf "$W" "$OUTD"' EXIT
fails=0; ran=0
ok()  { ran=$((ran+1)); echo "  ok    $1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); echo "  FAIL  $1"; }

[ -r "$TABLE" ] && [ -r "$RUNNER" ] || { echo "FATAL: table or runner unreadable"; exit 2; }

# messages the runner can emit: the literal text after `_fail "`
grep -oE '_fail "[^"]*' "$RUNNER" | sed 's/^_fail "//' > "$W/msgs"
[ "$(wc -l < "$W/msgs")" -gt 100 ] || { echo "FATAL: extracted only $(wc -l < "$W/msgs") failure messages from the runner"; exit 2; }

rows=0
while IFS=$'\t' read -r b c g why; do
  [[ -z "$b" || "$b" == \#* ]] && continue
  rows=$((rows+1))
  case " $GA_BOARDS " in *" $b "*) ;; *) bad "row '$g': unknown board '$b'"; continue ;; esac
  case "$c" in -|core-skipped|no-addons) ;; *) bad "row '$g': unknown condition '$c'"; continue ;; esac
  [ -n "$why" ] || { bad "row '$g': no reason"; continue; }
  hit=0
  while IFS= read -r m; do
    # shellcheck disable=SC2053
    [[ "$m" == $g ]] && { hit=1; break; }
  done < "$W/msgs"
  [ "$hit" = 1 ] && ok "row '$g' ($b): matches a failure message of the runner" || bad "row '$g' ($b): matches no failure message of the runner"
  mk="$ROOT/$(ga_board_var BOARD_DIR "$b")/external.mk"
  case "$c" in
    core-skipped) sed -n 's/^GA_HASSIO_SKIP_IMAGES[[:space:]]*=[[:space:]]*//p' "$mk" | grep -qw core \
                    && ok "row '$g': $b's external.mk declares no Core image" || bad "row '$g': condition core-skipped is false for $b" ;;
    no-addons)    ! grep -q '^HASSIO_ADDON_IMAGES_JSON' "$mk" \
                    && ok "row '$g': $b's external.mk names no add-on list" || bad "row '$g': condition no-addons is false for $b" ;;
  esac
done < "$TABLE"
[ "$rows" -ge 8 ] && ok "the table has $rows rows (fail closed on an empty table)" || bad "only $rows rows read"

# --- the runner on a fixture (a target with nothing in it: the listed hardware checks fail) ---
mkdir -p "$OUTD/target/usr"
run() {  # <board> [table]
  GA_BOARD="$1" GA_BUILD_BOARD_SKIPS="${2:-$TABLE}" bash "$RUNNER" "$OUTD" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}
dsgw="$(run dsgw210)"; ihost="$(run ihost)"
printf '%s\n' "$dsgw" | grep -qE '^  SKIP  CFG-30a \(not applicable to board dsgw210: ga-openstick-autoconnect' \
  && ok "dsgw210: CFG-30a is SKIPPED with its reason" || bad "dsgw210: CFG-30a not skipped with the reason"
printf '%s\n' "$ihost" | grep -qE '^  FAIL  CFG-30a:' \
  && ok "ihost: the same check still FAILS" || bad "ihost: CFG-30a is not a FAIL"
printf '%s\n' "$ihost" | grep -q 'not applicable to board' \
  && bad "ihost: a check was skipped as board-specific" || ok "ihost: nothing is skipped as board-specific"
printf '%s\n' "$dsgw" | grep -qE '^  FAIL  CFG-01:' \
  && ok "dsgw210: an unlisted check (CFG-01) still FAILS" || bad "dsgw210: CFG-01 no longer fails — over-skipping"
printf '%s\n' "$dsgw" | grep -qE '^Board skips applied for dsgw210' \
  && ok "dsgw210: the applied skips are listed once more at the end" || bad "dsgw210: no summary line of the applied skips"
# fail closed
printf 'dsgw210\t-\tCFG-30*\t\n' > "$W/noreason.tsv"
run dsgw210 "$W/noreason.tsv" | grep -qE '^  FAIL  CFG-30a:' \
  && ok "a row without a reason skips nothing" || bad "a row without a reason skipped a check"
printf 'dsgw210\tbogus\tCFG-30*\twhy\n' > "$W/badcond.tsv"
run dsgw210 "$W/badcond.tsv" | grep -qE '^  FAIL  CFG-30a:' \
  && ok "an unknown condition skips nothing" || bad "an unknown condition skipped a check"
run dsgw210 "$W/does-not-exist.tsv" | grep -qE '^  FAIL  CFG-30a:' \
  && ok "a missing table skips nothing" || bad "a missing table skipped a check"

echo
[ "$ran" -ge 20 ] || { echo "FAIL: only $ran cases ran"; exit 1; }
[ "$fails" -eq 0 ] && { echo "all $ran cases passed"; exit 0; }
echo "$fails of $ran case(s) failed"; exit 1
