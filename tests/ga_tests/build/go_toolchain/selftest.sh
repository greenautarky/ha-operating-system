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
for f in ga_go_expected_version ga_go_toolchain_verdict ga_go_scan ga_go_floor_version ga_go_floor_verdict ga_go_modfloor_list ga_go_modfloor_exempt_list ga_go_modfloor_verdict ga_go_scan_mods ga_go_stamp_id ga_go_rebuild_if_toolchain_changed; do
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


# --- GOTC-05 verdict: no Go binary embeds a vendored module below its floor ----
# BOSv1.5.1-rc2: golang.org/x/net 0.55-0.59 (GO-2026-6612, Critical, fixed 0.60.0)
# and x/crypto 0.48 (GHSA-rm3j-f69w-wqmq, Critical) in containerd/docker/netbird/
# telegraf. The go-toolchain floor (GOTC-04) says nothing about vendored modules.
# MFLOORS is a PINNED constant here: the verdict is held to it, not to the live
# go-modfloor.mk (inputs_check.sh holds that file to a minimum).
MFLOORS=$'golang.org/x/net v0.60.0\ngolang.org/x/crypto v0.57.0\ngolang.org/x/text v0.42.0\ngolang.org/x/mod v0.41.0'
declare -A MFLAG=(
  [rc2-shaped]="1 10"
  [runc-bake-rc3]="1 1"
  [net-one-below]="1 1"
  [crypto-only-below]="1 1"
  [text-below]="1 1"
  [mod-below]="1 1"
  [pseudo-version]="1 1"
  [single-digit-minor]="1 1"
  [replace-downgrades]="1 1"
  [replace-by-other-module]="1 1"
  [one-bad-among-good]="1 1"
  [empty]="2 0"
  [not-a-scan]="2 0"
)
_mjudge() {  # $1 fn, $2 file
  local out rc
  out="$("$1" "$MFLOORS" < "$2")"; rc=$?
  printf '%s %s\n' "$rc" "$(printf '%s' "$out" | grep -c . || true)"
}
_mall() {  # $1 fn, $2 report? -> number of mismatches
  local fn="$1" report="${2:-}" bad=0 f name got want
  for f in "$FX"/modfloor/must-flag/*.mods; do
    name="$(basename "$f" .mods)"; want="${MFLAG[$name]:-}"; got="$(_mjudge "$fn" "$f")"
    if [ -n "$want" ] && [ "$got" = "$want" ]; then
      [ -n "$report" ] && _pass "GOTC-FX-MF-F: $name flagged (rc offenders = $got)"
    else
      [ -n "$report" ] && _fail "GOTC-FX-MF-F: $name: got '$got', want '${want:-<no pinned verdict>}'"
      bad=$((bad+1))
    fi
  done
  for f in "$FX"/modfloor/must-pass/*.mods; do
    name="$(basename "$f" .mods)"; got="$(_mjudge "$fn" "$f")"
    if [ "$got" = "0 0" ]; then
      [ -n "$report" ] && _pass "GOTC-FX-MF-P: $name accepted"
    else
      [ -n "$report" ] && _fail "GOTC-FX-MF-P: $name: got '$got', want '0 0'"
      bad=$((bad+1))
    fi
  done
  return "$bad"
}
_nmf=$(ls "$FX"/modfloor/must-flag/*.mods 2>/dev/null | wc -l)
_nmp=$(ls "$FX"/modfloor/must-pass/*.mods 2>/dev/null | wc -l)
if [ "$_nmf" -lt "${#MFLAG[@]}" ] || [ "$_nmp" -lt 5 ]; then
  _fail "GOTC-FX-MF-01: modfloor fixture sets incomplete (must-flag $_nmf of ${#MFLAG[@]}, must-pass $_nmp)"
else
  _pass "GOTC-FX-MF-01: $_nmf must-flag + $_nmp must-pass modfloor fixtures present"
fi
_mall ga_go_modfloor_verdict report
for bad_floors in "" "golang.org/x/net" "golang.org/x/net v0.60" "golang.org/x/net 0.60.0"; do
  ga_go_modfloor_verdict "$bad_floors" < "$FX/modfloor/must-pass/all-at-floor.mods" >/dev/null; rc=$?
  [ "$rc" = 2 ] && _pass "GOTC-FX-MF-E: floors '$bad_floors' refused (rc 2)" || _fail "GOTC-FX-MF-E: floors '$bad_floors' gave rc $rc, want 2"
done
# the module reader counts what it inspected (a verdict over zero floored modules is a broken reader)
ga_go_modfloor_verdict "$MFLOORS" < "$FX/modfloor/must-pass/all-at-floor.mods" >/dev/null
[ "$GA_GO_MODS_SEEN" = 4 ] && _pass "GOTC-FX-MF-C: all-at-floor read 4 floored module entries" || _fail "GOTC-FX-MF-C: read ${GA_GO_MODS_SEEN:-?} floored entries, want 4"
# the floors parser reads the live-shaped go-modfloor.mk and refuses a file without floor lines
_mfl="$(ga_go_modfloor_list "$FX/modfloor/ext-good")"
[ "$_mfl" = $'golang.org/x/net v0.60.0\ngolang.org/x/text v0.42.0' ] && _pass "GOTC-FX-MF-L: floors read from go-modfloor.mk" || _fail "GOTC-FX-MF-L: read '$_mfl'"
for c in ext-malformed ext-none ext-missing; do
  if _o="$(ga_go_modfloor_list "$FX/modfloor/$c")"; then _fail "GOTC-FX-MF-L: $c yielded '$_o' - must refuse"; else _pass "GOTC-FX-MF-L: $c refused"; fi
done

_mmutant() {  # $1 label, $2 sed expression applied to the live lib; judged by the modfloor fixtures
  local m="$WORK/mm.sh"
  sed "$2" "$LIB" > "$m"
  if cmp -s "$m" "$LIB"; then
    _fail "GOTC-FX-X: mutant '$1' did not apply - the live lib changed shape; update the mutant"
    return
  fi
  # shellcheck source=/dev/null
  if ( . "$m"; _mall ga_go_modfloor_verdict ); then
    _fail "GOTC-FX-X: mutant '$1' passes every modfloor fixture - the fixtures do not guard it"
  else
    _pass "GOTC-FX-X: mutant '$1' caught by the modfloor fixtures"
  fi
}


# --- GOTC-05 exemptions: pinned, expiring, never wider than written -------------
# BOSv1.5.1-rc3: runc 1.4.3 links only golang.org/x/net/bpf from x/net and does not
# compile against a bumped x/net, so the floor has ONE reasoned, time-boxed exemption
# (buildroot-external/go-modfloor.exempt). XEX is a PINNED copy here, like MFLOORS:
# the verdict is held to it, not to the live file (inputs_check.sh GOTC-IN-10 holds
# the live file to its own pinned constants).
XEX='usr/bin/runc|golang.org/x/net|v0.43.0|GO-2026-6612,GO-2026-6617|2026-11-30|runc links only x/net/bpf; module-level advisories only'
_xjudge() {  # $1 fn, $2 file, $3 today, $4 exemptions -> "rc offenders"
  local out rc
  out="$("$1" "$MFLOORS" "$4" "$3" < "$2")"; rc=$?
  printf '%s %s\n' "$rc" "$(printf '%s' "$out" | grep -c . || true)"
}
# name|today|want   (must-pass dir => want "0 0"; must-flag dir => pinned verdict)
XCASES=(
  "must-pass/runc-pinned|2026-10-13|0 0"
  "must-pass/runc-pinned|2026-11-30|0 0"
  "must-pass/runc-pinned-beside-clean-binary|2026-10-13|0 0"
  "must-pass/runc-bumped-to-floor|2026-10-13|0 0"
  "must-flag/runc-pinned|2026-12-01|1 2"
  "must-flag/runc-bumped-to-floor|2026-12-01|1 1"
  "must-flag/runc-other-version|2026-10-13|1 1"
  "must-flag/runc-downgraded|2026-10-13|1 1"
  "must-flag/other-binary-same-version|2026-10-13|1 1"
  "must-flag/runc-pinned-plus-other-bad|2026-10-13|1 1"
  "must-flag/runc-other-path|2026-10-13|1 1"
  "must-flag/runc-other-module-below|2026-10-13|1 1"
)
_xall() {  # $1 fn, $2 report? -> number of mismatches
  local fn="$1" report="${2:-}" bad=0 c name today want dir f got
  for c in "${XCASES[@]}"; do
    IFS='|' read -r name today want <<<"$c"
    dir="${name%%/*}"; name="${name#*/}"
    f="$FX/modfloor/exempt/$dir/$name.mods"
    # the expiry cases reuse a must-pass scan: resolve whichever dir holds the file
    [ -f "$f" ] || f="$FX/modfloor/exempt/must-pass/$name.mods"
    got="$(_xjudge "$fn" "$f" "$today" "$XEX")"
    if [ "$got" = "$want" ]; then [ -n "$report" ] && _pass "GOTC-FX-XM: $name @ $today -> '$got'"
    else [ -n "$report" ] && _fail "GOTC-FX-XM: $name @ $today: got '$got', want '$want'"; bad=$((bad+1)); fi
  done
  return "$bad"
}
_nxf=$(ls "$FX"/modfloor/exempt/must-flag/*.mods 2>/dev/null | wc -l)
_nxp=$(ls "$FX"/modfloor/exempt/must-pass/*.mods 2>/dev/null | wc -l)
[ "$_nxf" -ge 6 ] && [ "$_nxp" -ge 3 ] && _pass "GOTC-FX-XM-01: $_nxf must-flag + $_nxp must-pass exemption fixtures present" || _fail "GOTC-FX-XM-01: exemption fixture sets incomplete (must-flag $_nxf, must-pass $_nxp)"
_xall ga_go_modfloor_verdict report
# no exemptions given: the same scan the exemption honours is a plain offender
_g="$(_xjudge ga_go_modfloor_verdict "$FX/modfloor/exempt/must-pass/runc-pinned.mods" 2026-10-13 "")"
[ "$_g" = "1 1" ] && _pass "GOTC-FX-XM-N: without the exemption the pinned runc scan is flagged (red proof for the exemption)" || _fail "GOTC-FX-XM-N: got '$_g', want '1 1'"
# the exemption is counted, not silent
ga_go_modfloor_verdict "$MFLOORS" "$XEX" 2026-10-13 < "$FX/modfloor/exempt/must-pass/runc-pinned.mods" >/dev/null
[ "${GA_GO_EXEMPTED:-}" = 1 ] && _pass "GOTC-FX-XM-C: the exempted entry is counted (GA_GO_EXEMPTED=1)" || _fail "GOTC-FX-XM-C: GA_GO_EXEMPTED='${GA_GO_EXEMPTED:-}', want 1"
# malformed exemptions are refused (rc 2), never ignored
for bad_x in 'usr/bin/runc|golang.org/x/net|v0.43.0|GO-2026-6612|2026-11-30' \
             'usr/bin/runc|golang.org/x/net|0.43.0|GO-2026-6612|2026-11-30|why' \
             'usr/bin/runc|golang.org/x/net|v0.43.0|CVE-2026-1|2026-11-30|why' \
             'usr/bin/runc|golang.org/x/net|v0.43.0|GO-2026-6612|30.11.2026|why' \
             'usr/bin/runc|golang.org/x/net|v0.43.0|GO-2026-6612|2026-11-30|' \
             'usr/bin/runc|golang.org/x/net|v0.43.0|GO-2026-6612|2026-11-30|why|extra'; do
  ga_go_modfloor_verdict "$MFLOORS" "$bad_x" 2026-10-13 < "$FX/modfloor/exempt/must-pass/runc-pinned.mods" >/dev/null; rc=$?
  [ "$rc" = 2 ] && _pass "GOTC-FX-XM-E: malformed exemption refused (rc 2): ${bad_x:0:60}" || _fail "GOTC-FX-XM-E: '$bad_x' gave rc $rc, want 2"
done
ga_go_modfloor_verdict "$MFLOORS" "$XEX" 30.11.2026 < "$FX/modfloor/exempt/must-pass/runc-pinned.mods" >/dev/null; rc=$?
[ "$rc" = 2 ] && _pass "GOTC-FX-XM-E: malformed TODAY refused (rc 2)" || _fail "GOTC-FX-XM-E: malformed TODAY gave rc $rc, want 2"
# the exempt-list reader: comments stripped, a missing file is "no exemptions"
_xl="$(ga_go_modfloor_exempt_list "$REPO_ROOT/buildroot-external")"
[ "$(grep -c . <<<"$_xl")" = 1 ] && [[ "$_xl" == usr/bin/runc\|golang.org/x/net\|* ]] && _pass "GOTC-FX-XM-L: the live go-modfloor.exempt yields one runc entry (comments stripped)" || _fail "GOTC-FX-XM-L: live exempt list read as '$_xl'"
[ -z "$(ga_go_modfloor_exempt_list "$FX/modfloor/ext-missing")" ] && _pass "GOTC-FX-XM-L: a missing exempt file means no exemptions" || _fail "GOTC-FX-XM-L: missing file yielded entries"
# the LIVE exemption entry parses under the LIVE verdict (a malformed live file is rc 2 = red in GOTC-05)
ga_go_modfloor_verdict "$MFLOORS" "$_xl" 2026-10-13 < "$FX/modfloor/exempt/must-pass/runc-pinned.mods" >/dev/null; rc=$?
[ "$rc" = 0 ] && _pass "GOTC-FX-XM-LIVE: the live exemption entry exempts the runc 1.4.3 scan before expiry" || _fail "GOTC-FX-XM-LIVE: live entry gave rc $rc on the runc scan, want 0"

_xmutant() {  # $1 label, $2 sed expression applied to the live lib; judged by the exemption fixtures
  local m="$XW/xm.sh"
  sed "$2" "$LIB" > "$m"
  if cmp -s "$m" "$LIB"; then _fail "GOTC-FX-XX: mutant '$1' did not apply - the live lib changed shape; update the mutant"; return; fi
  # shellcheck source=/dev/null
  if ( . "$m"; _xall ga_go_modfloor_verdict ); then _fail "GOTC-FX-XX: mutant '$1' passes every exemption fixture - the fixtures do not guard it"
  else _pass "GOTC-FX-XX: mutant '$1' caught by the exemption fixtures"; fi
}
XW="$(mktemp -d)"
_xmutant "expiry ignored"          's/! "\${_xexp\[\$_key\]}" < "\$_today" && //'
_xmutant "version pin ignored"     's/ && "\$_ver" == "\${_xver\[\$_key\]}"//'
_xmutant "path ignored (any binary)" 's/_key="\$_cur|\$_mod"/_key="usr\/bin\/runc|$_mod"/'
_xmutant "expired entry not reported" 's/if \[\[ "\${_xexp\[\$_key\]}" < "\$_today" \]\]; then/if false; then/'
rm -rf "$XW"

# --- the module floors reach a REUSED output tree (ga_go_stamp_id) --------------
# Buildroot runs a POST_PATCH hook once per package build dir. Without the floors
# in the recorded stamp, an `update` bake would keep the old netbird/telegraf/
# docker/containerd for ever and stay green. make is stubbed (it is what the
# subject calls out to); the stamp logic under test is the LIVE one.
SW="$(mktemp -d)"; trap 'rm -rf "$SW" "${WORK:-}"' EXIT
mkdir -p "$SW/ext" "$SW/out"
cp "$FX/modfloor/ext-good/go-modfloor.mk" "$SW/ext/"; echo "golang.org/x/net v0.60.0 h1:x=" > "$SW/ext/go-modfloor.sum"; echo "echo bump" > "$SW/bump.sh"
_id() { ga_go_stamp_id "1.26.9" "$SW/ext" "$SW/bump.sh"; }
_id1="$(_id)"
[ "$_id1" = "$(_id)" ] && [[ "$_id1" == 1.26.9+modfloor.* ]] && _pass "GOTC-FX-ST-1: stamp id is stable ($_id1)" || _fail "GOTC-FX-ST-1: unstable or malformed stamp id '$_id1'"
echo "GA_GO_MODFLOOR += golang.org/x/mod@v0.41.0" >> "$SW/ext/go-modfloor.mk"
_id2="$(_id)"; [ "$_id2" != "$_id1" ] && _pass "GOTC-FX-ST-2: a changed floor changes the stamp id" || _fail "GOTC-FX-ST-2: floor change left the stamp id unchanged"
echo "golang.org/x/mod v0.41.0 h1:y=" >> "$SW/ext/go-modfloor.sum"
_id3="$(_id)"; [ "$_id3" != "$_id2" ] && _pass "GOTC-FX-ST-3: a changed pinned hash changes the stamp id" || _fail "GOTC-FX-ST-3: sum change left the stamp id unchanged"
echo "echo bump2" > "$SW/bump.sh"
_id4="$(_id)"; [ "$_id4" != "$_id3" ] && _pass "GOTC-FX-ST-4: a changed bump script changes the stamp id" || _fail "GOTC-FX-ST-4: script change left the stamp id unchanged"
[ "$(ga_go_stamp_id 1.26.10 "$SW/ext" "$SW/bump.sh")" != "$_id4" ] && _pass "GOTC-FX-ST-5: a changed Go version changes the stamp id" || _fail "GOTC-FX-ST-5: Go version change left the stamp id unchanged"
if ga_go_stamp_id 1.26.9 "$SW/nowhere" "$SW/bump.sh" >/dev/null 2>&1; then _fail "GOTC-FX-ST-6: missing floors accepted"; else _pass "GOTC-FX-ST-6: missing floors refused (no stamp is better than a blind one)"; fi

# make stub: printvars answers the package list; <pkg>-dirclean is recorded
CALLS="$SW/calls"
make() {
  local a
  for a in "$@"; do
    case "$a" in
      printvars) printf 'PACKAGES=host-go netbird telegraf libglib2\nNETBIRD_DEPENDENCIES=host-go\nTELEGRAF_DEPENDENCIES=host-go\nLIBGLIB2_DEPENDENCIES=\n'; return 0;;
      *-dirclean) echo "${a%-dirclean}" >> "$CALLS"; return 0;;
    esac
  done
}
_reb() { : > "$CALLS"; ga_go_rebuild_if_toolchain_changed "$SW/out" ext "$1" >/dev/null 2>&1; echo "rc=$? $(sort "$CALLS" | tr '\n' ' ' | sed 's/ $//')"; }
[ "$(_reb "$_id4")" = "rc=0 netbird telegraf" ] && _pass "GOTC-FX-ST-7: no record -> every host-go package dircleaned, nothing else" || _fail "GOTC-FX-ST-7: got '$(_reb "$_id4")'"
ga_go_record_toolchain "$SW/out" "$_id4"
[ "$(_reb "$_id4")" = "rc=0 " ] && _pass "GOTC-FX-ST-8: recorded stamp -> no rebuild" || _fail "GOTC-FX-ST-8: got '$(_reb "$_id4")'"
echo "GA_GO_MODFLOOR += golang.org/x/crypto@v0.57.0" >> "$SW/ext/go-modfloor.mk"
[ "$(_reb "$(_id)")" = "rc=0 netbird telegraf" ] && _pass "GOTC-FX-ST-9: a floor edit after the last good build -> Go packages dircleaned" || _fail "GOTC-FX-ST-9: got '$(_reb "$(_id)")'"
unset -f make


# --- the seam: the LIVE GOTC block in run_build_tests.sh over a stub `go` -------
# The verdict functions are proven above; this proves the BLOCK that feeds them
# (pipeline, counters, messages). A first version of GOTC-05 lost its counters in
# a subshell and failed "reader is broken" on a perfectly good image - invisible
# to the function-level fixtures. Only `go` is stubbed (it reads binaries we do
# not have here): `go version` -> the pinned Go, `go version [-m] DIR` -> a scan
# fixture with the target path prefixed.
RBT="$REPO_ROOT/tests/ga_tests/run_build_tests.sh"
_bs="$(grep -n '^# Go toolchain consistency (GOTC)' "$RBT" | head -n 1 | cut -d: -f1)"
_be="$(grep -n '^total=\$((pass + fail + skip))' "$RBT" | head -n 1 | cut -d: -f1)"
if [ -z "$_bs" ] || [ -z "$_be" ] || [ "$_be" -le "$_bs" ]; then
  _fail "GOTC-FX-SEAM-0: cannot find the GOTC block in run_build_tests.sh - the seam test cannot run (FAIL, not skip)"
else
  BW="$(mktemp -d)"
  mkdir -p "$BW/out/target/usr/bin" "$BW/out/host/bin" "$BW/repo/buildroot/package/go"
  : > "$BW/out/target/usr/bin/netbird"
  printf 'GO_VERSION = 1.26.9\n' > "$BW/repo/buildroot/package/go/go.mk"
  cp -r "$REPO_ROOT/buildroot-external" "$BW/repo/buildroot-external" 2>/dev/null
  mkdir -p "$BW/repo/scripts/lib"; cp "$LIB" "$BW/repo/scripts/lib/go-toolchain.sh"
  cat > "$BW/out/host/bin/go" <<'GOSTUB'
#!/bin/bash
# stub: go version | go version DIR | go version -m DIR   (fixture in $GOSTUB_SCAN)
if [ "$1" = version ] && [ -z "${2:-}" ]; then echo "go version go1.26.9 linux/amd64"; exit 0; fi
if [ "$1" = version ]; then
  full=0; [ "$2" = "-m" ] && { full=1; shift; }
  d="${2%/}"
  if [ "$full" = 1 ]; then sed "/^[^[:space:]]/s#^#$d/#" "$GOSTUB_SCAN"
  else grep -E '^[^[:space:]]' "$GOSTUB_SCAN" | sed "s#^#$d/#"; fi
fi
GOSTUB
  chmod +x "$BW/out/host/bin/go"
  {
    printf 'pass=0 fail=0 skip=0; GREEN= RED= YELLOW= RESET=\n'
    printf '_pass() { echo "  PASS  $1"; pass=$((pass+1)); }\n_fail() { echo "  FAIL  $1"; fail=$((fail+1)); }\n_skip() { echo "  SKIP  $1 ($2)"; skip=$((skip+1)); }\n'
    printf 'OUT=%q; TARGET=$OUT/target; SRC=%q; BUILDROOT_DIR=%q; BR2EXT_NETBIRD=%q\n' "$BW/out" "$BW/repo" "$BW/repo/buildroot" "$BW/repo/buildroot-external"
    sed -n "${_bs},$((_be-1))p" "$RBT"
  } > "$BW/block.sh"
  _blk() { GOSTUB_SCAN="$1" bash "$BW/block.sh" 2>&1; }
  _g5() { grep -E 'GOTC-05' <<<"$1" | head -n 1; }
  o="$(_blk "$FX/modfloor/must-pass/all-at-floor.mods")"
  [[ "$(_g5 "$o")" == *"PASS"*"GOTC-05"* ]] && _pass "GOTC-FX-SEAM-1: block over a good image: GOTC-05 passes" || _fail "GOTC-FX-SEAM-1: good image -> '$(_g5 "$o")'"
  o="$(_blk "$FX/modfloor/must-flag/rc2-shaped.mods")"
  { [[ "$(_g5 "$o")" == *"FAIL"*"GOTC-05"* ]] && grep -q 'golang.org/x/net v0.59.0 (below floor v0.60.0)' <<<"$o"; } \
    && _pass "GOTC-FX-SEAM-2: block over the rc2-shaped image: GOTC-05 fails and names the offenders" || _fail "GOTC-FX-SEAM-2: rc2-shaped image -> '$(_g5 "$o")'"
  o="$(_blk "$FX/modfloor/must-pass/binary-without-floored-modules.mods")"
  [[ "$(_g5 "$o")" == *"FAIL"*"reader is broken"* ]] && _pass "GOTC-FX-SEAM-3: an image with zero floored entries fails closed (reader broken)" || _fail "GOTC-FX-SEAM-3: zero floored entries -> '$(_g5 "$o")'"
  # exemption through the real block: expiry rewritten in the COPY (the live date must not make this suite flaky)
  XF="$BW/repo/buildroot-external/go-modfloor.exempt"; XFL="$FX/modfloor/exempt/must-pass/runc-pinned.mods"
  sed -i 's/|2026-11-30|/|2099-01-01|/' "$XF"
  o="$(_blk "$XFL")"
  { [[ "$(_g5 "$o")" == *"PASS"*"GOTC-05"* ]] && grep -q '1 below-floor entries allowed by a pinned' <<<"$o"; } \
    && _pass "GOTC-FX-SEAM-4: block: runc at the pinned x/net under an unexpired exemption passes, and says it was exempted" || _fail "GOTC-FX-SEAM-4: pinned runc -> '$(_g5 "$o")'"
  sed -i 's/|2099-01-01|/|2020-01-01|/' "$XF"
  o="$(_blk "$XFL")"
  { [[ "$(_g5 "$o")" == *"FAIL"*"GOTC-05"* ]] && grep -q 'exemption for golang.org/x/net EXPIRED 2020-01-01' <<<"$o"; } \
    && _pass "GOTC-FX-SEAM-5: block: the same runc after the expiry date fails and names the expired exemption" || _fail "GOTC-FX-SEAM-5: expired -> '$(_g5 "$o")'"
  rm -f "$XF"
  o="$(_blk "$XFL")"
  { [[ "$(_g5 "$o")" == *"FAIL"*"GOTC-05"* ]] && grep -q 'usr/bin/runc: golang.org/x/net v0.43.0 (below floor v0.60.0)' <<<"$o"; } \
    && _pass "GOTC-FX-SEAM-6: block: without an exemption file the same runc fails (strict by default)" || _fail "GOTC-FX-SEAM-6: no exemption file -> '$(_g5 "$o")'"
  rm -rf "$BW"
fi

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

_mmutant "version compared as text (v0.100.0 < v0.60.0)" 's/_low="$(printf .%s\\n%s\\n. "${_ver#v}" "${_fv#v}" | sort -V | head -n 1)"/_low="$(printf "%s\\n%s\\n" "${_ver#v}" "${_fv#v}" | LC_ALL=C sort | head -n 1)"/'
_mmutant "verdict never fails (always rc 0)" '/^ga_go_modfloor_verdict/,/^}/s/^  return "$_bad"$/  return 0/'
_mmutant "empty scan passes the modfloor" '/^ga_go_modfloor_verdict/,/^}/s/(( GA_GO_SCANNED > 0 )) || return 2/:/'
_mmutant "replace line ignored" "s/'=>')    # replace line/'=>__')    # replace line/"

# stamp id that forgets the pinned hashes must be caught by ST-3
_sm="$WORK/sm.sh"; sed 's#cat "$_ext/go-modfloor.mk" "$_ext/go-modfloor.sum" "$_bump"#cat "$_ext/go-modfloor.mk" "$_bump"#' "$LIB" > "$_sm"
if cmp -s "$_sm" "$LIB"; then _fail "GOTC-FX-X: mutant 'stamp ignores the sums' did not apply"
else
  # shellcheck source=/dev/null
  _a="$( . "$_sm"; ga_go_stamp_id 1.26.9 "$SW/ext" "$SW/bump.sh")"; echo "x" >> "$SW/ext/go-modfloor.sum"
  _b="$( . "$_sm"; ga_go_stamp_id 1.26.9 "$SW/ext" "$SW/bump.sh")"
  [ "$_a" = "$_b" ] && _pass "GOTC-FX-X: mutant 'stamp ignores the sums' is blind to a sum edit - ST-3 would catch it" || _fail "GOTC-FX-X: mutant 'stamp ignores the sums' still sees the edit"
fi

echo ""
echo "=== GOTC fixtures: ${pass} passed, ${fail} failed ==="
[ "$fail" -eq 0 ]
