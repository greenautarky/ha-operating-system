#!/usr/bin/env bash
# Fixtures for the Go-toolchain consistency check (GOTC-03 in run_build_tests.sh).
#
# WHAT THIS EXISTS FOR
# ====================
# BOSv1.5.0-rc4 shipped netbird, os-agent and runc built with go1.26.5 while
# buildroot pinned go1.26.8 (#710). Buildroot does not rebuild a package when
# host-go changes, and nothing compared the two versions. GOTC-03 now does; this
# file holds its verdict to fixtures so a later edit cannot quietly turn it into
# a check that always passes or always fails.
#
#   * It sources the LIVE scripts/lib/go-toolchain.sh. It never re-declares the
#     verdict. If the function stops being found, it FAILS (never skips).
#   * must-flag: scans the verdict MUST reject, each with its pinned exit code
#     and offender count. rc4-target.scan is the real BOSv1.5.0-rc4 target scan.
#   * must-pass: scans it MUST accept. Every false positive ever fixed goes here.
#   * mutants: two plausible weakenings of the live verdict (prefix compare,
#     no fail-closed on an empty scan) must each be caught by the fixtures.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/go-toolchain.sh"
FX="$HERE/fixtures"
EXP="1.26.8"
pass=0 fail=0

_pass() { echo "  PASS  $1"; pass=$((pass+1)); }
_fail() { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "=== Go toolchain consistency: verdict fixtures ==="

[ -f "$LIB" ] || { echo "  FAIL  GOTC-FX-00: live lib not found at $LIB"; exit 1; }
# shellcheck source=../../../../scripts/lib/go-toolchain.sh
. "$LIB"
for f in ga_go_expected_version ga_go_toolchain_verdict ga_go_scan ga_go_floor_version ga_go_floor_verdict; do
  declare -F "$f" >/dev/null || { echo "  FAIL  GOTC-FX-00: $f not defined by the live lib"; exit 1; }
done
_pass "GOTC-FX-00: live verdict functions found in scripts/lib/go-toolchain.sh"

# fixture-name -> "rc offenders"
declare -A FLAG=(
  [rc4-target]="1 3"
  [version-prefix]="1 1"
  [older-minor]="1 1"
  [devel]="1 1"
  [no-version]="1 1"
  [empty]="2 0"
  [reader-error]="1 1"
  [not-a-scan-line]="2 1"
)

# _run_set VERDICT_FN -> prints "name rc offenders" per fixture
_judge() {  # $1 fn, $2 file
  local out rc
  out="$("$1" "$EXP" < "$2")"; rc=$?
  printf '%s %s\n' "$rc" "$(printf '%s' "$out" | grep -c . || true)"
}

_check_all() {  # $1 fn ; returns number of fixture mismatches, prints FAIL/PASS when $2=report
  local fn="$1" report="${2:-}" bad=0 f name got want
  for f in "$FX"/must-flag/*.scan; do
    name="$(basename "$f" .scan)"
    want="${FLAG[$name]:-}"
    if [ -z "$want" ]; then
      [ -n "$report" ] && _fail "GOTC-FX-F: must-flag fixture $name has no pinned verdict in this file"
      bad=$((bad+1)); continue
    fi
    got="$(_judge "$fn" "$f")"
    if [ "$got" = "$want" ]; then
      [ -n "$report" ] && _pass "GOTC-FX-F: $name flagged (rc offenders = $got)"
    else
      [ -n "$report" ] && _fail "GOTC-FX-F: $name: got rc/offenders '$got', want '$want'"
      bad=$((bad+1))
    fi
  done
  for f in "$FX"/must-pass/*.scan; do
    name="$(basename "$f" .scan)"
    got="$(_judge "$fn" "$f")"
    if [ "$got" = "0 0" ]; then
      [ -n "$report" ] && _pass "GOTC-FX-P: $name accepted"
    else
      [ -n "$report" ] && _fail "GOTC-FX-P: $name: got rc/offenders '$got', want '0 0'"
      bad=$((bad+1))
    fi
  done
  return "$bad"
}

_nflag=$(ls "$FX"/must-flag/*.scan 2>/dev/null | wc -l)
_npass=$(ls "$FX"/must-pass/*.scan 2>/dev/null | wc -l)
if [ "$_nflag" -lt "${#FLAG[@]}" ] || [ "$_npass" -lt 1 ]; then
  _fail "GOTC-FX-01: fixture sets incomplete (must-flag $_nflag of ${#FLAG[@]}, must-pass $_npass)"
else
  _pass "GOTC-FX-01: $_nflag must-flag + $_npass must-pass fixtures present"
fi

_check_all ga_go_toolchain_verdict report

# A malformed expectation is "nothing to judge", never a pass.
for bad_exp in "" "1.26.8x" "go1.26.8"; do
  ga_go_toolchain_verdict "$bad_exp" < "$FX/must-pass/all-current.scan" >/dev/null; rc=$?
  [ "$rc" = 2 ] && _pass "GOTC-FX-E: expected '$bad_exp' refused (rc 2)" \
                || _fail "GOTC-FX-E: expected '$bad_exp' gave rc $rc, want 2"
done

# --- the expected value comes from buildroot's go.mk ---------------------------
v="$(ga_go_expected_version "$FX/buildroot-good")"
[ "$v" = "1.26.8" ] && _pass "GOTC-FX-M1: GO_VERSION read from go.mk ($v)" \
                    || _fail "GOTC-FX-M1: read '$v' from a go.mk pinning 1.26.8"
for c in indirect commented missing; do
  if v="$(ga_go_expected_version "$FX/buildroot-$c")"; then
    _fail "GOTC-FX-M2: go.mk case '$c' yielded '$v' — must refuse"
  else
    _pass "GOTC-FX-M2: go.mk case '$c' refused"
  fi
done

# --- the Go floor: expected version = max(go.mk, GA_GO_VERSION_FLOOR) ---------
# Odoo #1231: the submodule pins 1.26.8, GO-2026-6604/6612 are fixed in 1.26.9.
# The carry (buildroot-external/go-floor.mk) raises the build to the floor; the
# guard must follow it, and must follow a LATER submodule bump past the floor.
_exp_case() {  # $1 fixture dir, $2 wanted version ("" = must refuse)
  local v rc
  v="$(ga_go_expected_version "$FX/$1" "$FX/$1/ext")"; rc=$?
  if [ -z "$2" ]; then
    [ "$rc" != 0 ] && [ -z "$v" ] && _pass "GOTC-FX-V: $1 refused" || _fail "GOTC-FX-V: $1 gave '$v' (rc $rc), must refuse"
  else
    [ "$rc" = 0 ] && [ "$v" = "$2" ] && _pass "GOTC-FX-V: $1 -> $v" || _fail "GOTC-FX-V: $1 gave '$v' (rc $rc), want '$2'"
  fi
}
_exp_case ext-floor-higher 1.26.9      # submodule 1.26.8, floor 1.26.9 -> floor wins
_exp_case ext-floor-lower 1.27.0       # submodule already past the floor -> never downgraded
_exp_case ext-floor-malformed ""       # unreadable floor -> refuse, do not fall back to go.mk
_exp_case ext-no-floor ""              # go-floor.mk present but the assignment gone -> refuse (never silently fall back to go.mk)
v="$(ga_go_expected_version "$FX/ext-floor-higher")"
[ "$v" = "1.26.8" ] && _pass "GOTC-FX-V: no external dir given -> go.mk only ($v)" || _fail "GOTC-FX-V: no external dir gave '$v'"

# --- GOTC-04 verdict: no Go binary below the floor ---------------------------
FLOOR="1.26.9"
declare -A FLOORFLAG=(
  [all-1.26.8-consistent-but-old]="1 8"
  [one-stale-1.26.5]="1 1"
  [devel]="1 1"
  [bare-minor-is-dot-zero]="1 1"
  [empty]="2 0"
  [not-a-scan-line]="2 1"
)
_floor_judge() {  # $1 fn, $2 file
  local out rc
  out="$("$1" "$FLOOR" < "$2")"; rc=$?
  printf '%s %s\n' "$rc" "$(printf '%s' "$out" | grep -c . || true)"
}
_floor_all() {  # $1 fn, $2 report?  -> returns number of mismatches
  local fn="$1" report="${2:-}" bad=0 f name got want
  for f in "$FX"/floor/must-flag/*.scan; do
    name="$(basename "$f" .scan)"; want="${FLOORFLAG[$name]:-}"
    got="$(_floor_judge "$fn" "$f")"
    # not-a-scan-line: rc 2 (nothing scanned) with the line reported
    if [ -n "$want" ] && [ "$got" = "$want" ]; then
      [ -n "$report" ] && _pass "GOTC-FX-FL-F: $name flagged (rc offenders = $got)"
    else
      [ -n "$report" ] && _fail "GOTC-FX-FL-F: $name: got '$got', want '${want:-<no pinned verdict>}'"
      bad=$((bad+1))
    fi
  done
  for f in "$FX"/floor/must-pass/*.scan; do
    name="$(basename "$f" .scan)"; got="$(_floor_judge "$fn" "$f")"
    if [ "$got" = "0 0" ]; then
      [ -n "$report" ] && _pass "GOTC-FX-FL-P: $name accepted"
    else
      [ -n "$report" ] && _fail "GOTC-FX-FL-P: $name: got '$got', want '0 0'"
      bad=$((bad+1))
    fi
  done
  return "$bad"
}
_floor_all ga_go_floor_verdict report
for bad_floor in "" "1.26" "go1.26.9" "1.26.9x"; do
  ga_go_floor_verdict "$bad_floor" < "$FX/floor/must-pass/all-1.26.9.scan" >/dev/null; rc=$?
  [ "$rc" = 2 ] && _pass "GOTC-FX-FL-E: floor '$bad_floor' refused (rc 2)" || _fail "GOTC-FX-FL-E: floor '$bad_floor' gave rc $rc, want 2"
done

# --- mutants: weakened copies of the LIVE lib must be caught -------------------
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
_mutant() {  # $1 label, $2 sed expression applied to the live lib
  local m="$WORK/m.sh"
  sed "$2" "$LIB" > "$m"
  if cmp -s "$m" "$LIB"; then
    _fail "GOTC-FX-X: mutant '$1' did not apply — the live lib changed shape; update the mutant"
    return
  fi
  if ( . "$m"; _check_all ga_go_toolchain_verdict ); then
    _fail "GOTC-FX-X: mutant '$1' passes every fixture — the fixtures do not guard it"
  else
    _pass "GOTC-FX-X: mutant '$1' caught by the fixtures"
  fi
}
_mutant "prefix compare" 's/if \[\[ "\$_ver" != "go\${_exp}" \]\]; then/if [[ "$_ver" != "go${_exp}"* ]]; then/'
_mutant "empty scan passes" 's/(( GA_GO_SCANNED > 0 )) || return 2/:/'

_fmutant() {  # $1 label, $2 sed expression applied to the live lib; judged by the floor fixtures
  local m="$WORK/fm.sh"
  sed "$2" "$LIB" > "$m"
  if cmp -s "$m" "$LIB"; then
    _fail "GOTC-FX-X: mutant '$1' did not apply - the live lib changed shape; update the mutant"
    return
  fi
  # shellcheck source=/dev/null
  if ( . "$m"; _floor_all ga_go_floor_verdict ); then
    _fail "GOTC-FX-X: mutant '$1' passes every floor fixture - the fixtures do not guard it"
  else
    _pass "GOTC-FX-X: mutant '$1' caught by the floor fixtures"
  fi
}
_fmutant "floor compared as text (go1.26.10 < go1.26.9)" 's/_low="$(printf .%s\\n%s\\n. "${_ver#go}" "$_floor" | sort -V | head -n 1)"/_low="$(printf "%s\\n%s\\n" "${_ver#go}" "$_floor" | LC_ALL=C sort | head -n 1)"/'
_fmutant "floor verdict never fails (always rc 0)" 's/^  return "$_bad"$/  return 0/;t;'
_fmutant "empty scan passes the floor" '/^ga_go_floor_verdict/,/^}/s/(( GA_GO_SCANNED > 0 )) || return 2/:/'
# expected version ignoring the floor must be caught by the floor-higher case
_vm="$WORK/vm.sh"; sed 's/_v="$(printf .%s\\n%s\\n. "$_v" "$_f" | sort -V | tail -n 1)"/:/' "$LIB" > "$_vm"
if cmp -s "$_vm" "$LIB"; then _fail "GOTC-FX-X: mutant 'expected ignores the floor' did not apply"
else
  # shellcheck source=/dev/null
  v="$( . "$_vm"; ga_go_expected_version "$FX/ext-floor-higher" "$FX/ext-floor-higher/ext")"
  [ "$v" = "1.26.9" ] && _fail "GOTC-FX-X: mutant 'expected ignores the floor' still yields 1.26.9" || _pass "GOTC-FX-X: mutant 'expected ignores the floor' caught (yields $v)"
fi

echo ""
echo "=== GOTC fixtures: ${pass} passed, ${fail} failed ==="
[ "$fail" -eq 0 ]
