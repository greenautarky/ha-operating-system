#!/usr/bin/env bash
# ga_build.sh core_tag_valid (the post-build Core tag rule): the LIVE function,
# extracted from ga_build.sh, never re-declared here. A -dev Core tag is valid nowhere
# since Odoo #1985 (the Supervisor rates it AwesomeVersion UNKNOWN). If the function
# cannot be extracted the check FAILS (it never skips).
set -u
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
fn="$(awk '/^core_tag_valid\(\)/,/^}/' "$REPO/scripts/ga_build.sh")"
[ -n "$fn" ] || { echo "FAIL: core_tag_valid not found in scripts/ga_build.sh"; exit 1; }
bad=0 n=0
check() { # want(0|1) label tag channel release
  n=$((n+1)); bash -c "$fn"'
core_tag_valid "$1" "$2" "$3"' _ "$3" "$4" "$5"; rc=$?
  if [ "$rc" -eq "$1" ]; then echo "  ok    $2"; else echo "  FAIL  $2 (rc=$rc, want $1)"; bad=1; fi
}
check 0 "must-pass: plain pinned calver, stable"            2026.8.2.2        stable BOSv1.6.0-rc1
check 0 "must-pass: 3-part calver, stable"                  2026.8.2          stable BOSv1.6.0-rc1
check 0 "must-pass: legacy latest"                          latest            stable BOSv1.5.3
check 1 "must-fail: DSGW dev Core -dev on dev + -devN (Supervisor: UNKNOWN version, #1985)" 2026.10.4.3-dev   dev    BOSv1.6.0-dev1
check 0 "must-pass: plain calver on dev channel"            2026.10.4.3       dev    BOSv1.6.0-dev1
check 0 "must-pass: DSGW aarch64 release Core 2026.10.4.4"   2026.10.4.4       dev    BOSv1.6.0-dev1
check 1 "must-fail: -dev Core on stable channel"            2026.10.4.3-dev   stable BOSv1.6.0-dev1
check 1 "must-fail: -dev Core on dev channel, rc label"     2026.10.4.3-dev   dev    BOSv1.6.0-rc1
check 1 "must-fail: -dev Core on dev channel, final label"  2026.10.4.3-dev   dev    BOSv1.6.0
check 1 "must-fail: -dev Core, channel unreadable"          2026.10.4.3-dev   ""     BOSv1.6.0-dev1
check 1 "must-fail: other suffix (-rc1)"                    2026.10.4.3-rc1   dev    BOSv1.6.0-dev1
check 1 "must-fail: not a version"                          banana            dev    BOSv1.6.0-dev1
check 1 "must-fail: empty tag"                              ""                dev    BOSv1.6.0-dev1
# The build suite's copy (run_build_tests.sh core_tag_ok, the BLD check), extracted LIVE too:
# the same -dev rule; it does not accept the legacy `latest`; the suite requires a 4-digit year.
fn2="$(awk '/^core_tag_ok\(\)/,/^}/' "$REPO/tests/ga_tests/run_build_tests.sh")"
[ -n "$fn2" ] || { echo "FAIL: core_tag_ok not found in tests/ga_tests/run_build_tests.sh"; exit 1; }
check2() { # want label tag channel release
  n=$((n+1)); bash -c "$fn2"'
core_tag_ok "$1" "$2" "$3"' _ "$3" "$4" "$5"; rc=$?
  if [ "$rc" -eq "$1" ]; then echo "  ok    [suite] $2"; else echo "  FAIL  [suite] $2 (rc=$rc, want $1)"; bad=1; fi
}
check2 0 "must-pass: plain calver, stable"                 2026.8.2.2        stable BOSv1.6.0-rc1
check2 1 "must-fail: DSGW dev Core -dev on dev + -devN (Supervisor: UNKNOWN version, #1985)" 2026.10.4.3-dev   dev    BOSv1.6.0-dev5
check2 0 "must-pass: DSGW aarch64 release Core on dev + -devN"  2026.10.4.4       dev    BOSv1.6.0-dev5
check2 1 "must-fail: -dev Core on stable channel"          2026.10.4.3-dev   stable BOSv1.6.0-dev5
check2 1 "must-fail: -dev Core on dev channel, rc label"   2026.10.4.3-dev   dev    BOSv1.6.0-rc1
check2 1 "must-fail: -dev Core, release label unset"       2026.10.4.3-dev   dev    ""
check2 1 "must-fail: -dev Core, channel unreadable"        2026.10.4.3-dev   ""     BOSv1.6.0-dev5
check2 1 "must-fail: not a version"                        banana            dev    BOSv1.6.0-dev5
[ "$n" -ge 10 ] || { echo "FAIL: only $n cases ran"; exit 1; }
echo "$n cases ran"; exit "$bad"
