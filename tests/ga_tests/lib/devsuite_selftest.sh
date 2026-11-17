#!/bin/sh
# devsuite_selftest.sh - tiny harness for the host-side selftests of the on-device suites
# (tests/ga_tests/*_device, uplink_device, ...). Source it, then:
#
#   ds_init                         creates $W (work dir, removed on exit) and $W/bin (stub dir)
#   ds_run <suite> [VAR=val ...]    runs <suite>/test.sh with $W/bin first on PATH and the given
#                                   environment; output -> $W/out, status -> $W/rc
#   ds_expect <ID> <PASS|FAIL|SKIP> <why>   asserts the verdict line of that test id
#   ds_done                         prints the summary; exit 1 on any failure, 2 if nothing ran
#
# The SUITE under test is always the live test.sh; only the commands it talks to
# (docker, systemctl, journalctl, curl, ...) are stubs, and every suite selftest has BOTH a
# known-good state (must PASS) and broken states (must FAIL) - a check that cannot go red,
# or cannot go green, is not evidence (working-method rules 6, 45).
DS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DS_PASS=0; DS_FAIL=0

ds_init() {
  W="$(mktemp -d "${TMPDIR:-/tmp}/ds-XXXXXX")"
  trap 'rm -rf "$W"' EXIT
  mkdir -p "$W/bin"
  command -v jq >/dev/null 2>&1 || { echo "FATAL: jq missing"; exit 2; }
}

ds_run() {
  _s="$1"; shift
  # GA_T_SHELL="busybox sh" runs the suite under the device's shell (CI does both)
  # shellcheck disable=SC2086
  ( env PATH="$W/bin:$PATH" GA_T_DATA_ROOT=/nonexistent "$@" ${GA_T_SHELL:-sh} "$DS_ROOT/ga_tests/$_s/test.sh" > "$W/out" 2>&1; echo $? > "$W/rc" )
}

ds_expect() {   # ds_expect <ID> <PASS|FAIL|SKIP> <why>
  _line=$(grep -E "^ *(PASS|FAIL|SKIP|WARN) +$1:" "$W/out" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | head -1)
  _got=$(printf '%s' "$_line" | awk '{print $1}')
  if [ "$_got" = "$2" ]; then DS_PASS=$((DS_PASS + 1)); echo "  ok    $1 is $2 - $3"
  else DS_FAIL=$((DS_FAIL + 1)); echo "  FAIL  $1: wanted $2, got '${_got:-no verdict line}' - $3"; echo "        $(printf '%s' "$_line" | cut -c1-200)"; grep -A1 -E "^ *(PASS|FAIL|SKIP|WARN) +$1:" "$W/out" | sed -n 2p | cut -c1-300; fi
}

ds_done() {
  echo ""; echo "--- $DS_PASS ok, $DS_FAIL failed ---"
  [ $((DS_PASS + DS_FAIL)) -gt 0 ] || { echo "FATAL: no check ran"; exit 2; }
  [ "$DS_FAIL" = 0 ]
}
