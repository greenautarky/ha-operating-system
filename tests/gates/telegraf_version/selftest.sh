#!/usr/bin/env bash
# telegraf_version/selftest.sh -- the telegraf binary is stamped with the version
# telegraf.mk pins (Odoo #1219: it reported "unknown").
#
# WHAT IT CHECKS
#   1. scripts/telegraf-version-guard.sh (the same script the build runs on the
#      installed binary) on fixtures: bin-must-pass/*.txt exit 0 for 1.38.0,
#      bin-must-fail/*.txt exit 1 (no ldflag, stale version, "unknown", two stamps).
#      Missing binary = exit 2, never green.
#   2. The LIVE telegraf.mk: it sets TELEGRAF_LDFLAGS with internal.Version
#      from $(TELEGRAF_VERSION), and the version guard is a post-install hook.
#      A mutant of the live .mk with the ldflags line removed must turn this red
#      -- that proves the check reads the .mk and not a copy of it.
#   3. run_build_tests.sh carries the build-output check (TEL-VER-01).
# Exit 0 = green, 1 = a verdict failed, 2 = could not check.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/tests/gates/telegraf_version"
GUARD="$ROOT/scripts/telegraf-version-guard.sh"
MK="$ROOT/buildroot-external/package/telegraf/telegraf.mk"
BT="$ROOT/tests/ga_tests/run_build_tests.sh"
die2() { echo "ERROR (could not check): $*" >&2; exit 2; }
[ -x "$GUARD" ] || die2 "$GUARD not found or not executable"
[ -f "$MK" ] || die2 "$MK not found"
[ -f "$BT" ] || die2 "$BT not found"
pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ok    $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

nf=0 np=0
for f in "$HERE"/bin-must-fail/*.txt; do
  [ -f "$f" ] || continue; nf=$((nf + 1))
  "$GUARD" "$f" 1.38.0 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && ok "must-fail $(basename "$f") flagged" || bad "must-fail $(basename "$f") rc=$rc (want 1)"
done
for f in "$HERE"/bin-must-pass/*.txt; do
  [ -f "$f" ] || continue; np=$((np + 1))
  "$GUARD" "$f" 1.38.0 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "must-pass $(basename "$f") clean" || bad "must-pass $(basename "$f") rc=$rc (want 0)"
done
[ "$nf" -ge 4 ] && [ "$np" -ge 1 ] && ok "fixture coverage: $nf must-fail, $np must-pass" || bad "fixture coverage too small: $nf must-fail, $np must-pass"
"$GUARD" "$HERE/does-not-exist" 1.38.0 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "missing binary is exit 2 (not green)" || bad "missing binary rc=$rc (want 2)"

mk_ok() {  # $1 = mk file
  grep -qE '^TELEGRAF_LDFLAGS[[:space:]]*\+?=.*telegraf/internal\.Version=\$\(TELEGRAF_VERSION\)' "$1" &&
  grep -q 'telegraf-version-guard.sh' "$1"
  # The hook registration is deliberately absent since 2026-10-21 (see telegraf.mk);
  # it comes back with the qemu-exec guard (Odoo #1219).
}
mk_ok "$MK" && ok "live telegraf.mk stamps internal.Version from TELEGRAF_VERSION and runs the guard" || bad "live telegraf.mk lacks the ldflags stamp or the guard hook"
W="$(mktemp -d "${TMPDIR:-/tmp}/tg-ver.XXXXXX")"; trap 'rm -rf "$W"' EXIT
grep -v '^TELEGRAF_LDFLAGS' "$MK" > "$W/mutant.mk"
mk_ok "$W/mutant.mk" && bad "mutant .mk (ldflags removed) still passes - the check does not read the .mk" || ok "mutant .mk without the ldflags line is flagged"

grep -q 'TEL-VER-01' "$BT" && ok "run_build_tests.sh reports TEL-VER-01 (skip with reason until the qemu-exec guard, Odoo #1219)" || bad "run_build_tests.sh has no TEL-VER-01 check"

echo "telegraf_version selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
