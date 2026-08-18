#!/usr/bin/env bash
# selftest.sh — prove the provisioning gate's GRADING can go red and green.
#
# The gate itself needs a card, a MUX and a power plug, so it cannot run on a
# GitHub runner. Its verdict logic can: `--verify-only <root>` grades a device
# tree with no hardware at all. This runs that path against the same fixtures
# the phase-invariant selftest uses and asserts the EXIT CODE, because that is
# what a caller (a bake job, a cron, a person) will act on.
#
# Measured without a pipe on purpose: `cmd | grep …; echo $?` reports grep's
# status, which is how a gate can look green while failing. That mistake was
# made once while writing this file, which is exactly why the assertion is here.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/provision-e2e.sh"
FIXTURES="$HERE/../ga_tests/provisioning/fixtures"
fails=0
ran=0

[[ -x "$GATE" ]] || { echo "FATAL: $GATE missing or not executable"; exit 1; }
[[ -d "$FIXTURES" ]] || { echo "FATAL: fixtures dir missing: $FIXTURES"; exit 1; }

expect_exit() { # expect_exit <fixture> <wanted-exit>
  local fixture="$1" want="$2" rc out
  out="$("$GATE" --verify-only "$FIXTURES/$fixture" 2>&1)"; rc=$?
  ran=$((ran + 1))
  if [[ "$rc" -eq "$want" ]]; then
    echo "  ok    $fixture → exit $rc"
  else
    echo "  FAIL  $fixture → exit $rc (expected $want)"
    echo "$out" | sed 's/^/        /'
    fails=$((fails + 1))
  fi
}

echo "== the gate must REFUSE these trees =="
expect_exit must-fail-no-identity   1
expect_exit must-fail-parked-pw     1
expect_exit must-fail-baseline-only 1
echo "== and must PASS a finished device =="
expect_exit must-pass-converged     0

echo "== and must refuse to start without a device id =="
if "$GATE" >/dev/null 2>&1; then
  echo "  FAIL  ran without --device (preflight is decoration)"
  fails=$((fails + 1))
else
  rc=$?
  ran=$((ran + 1))
  if [[ $rc -eq 2 ]]; then
    echo "  ok    no --device → exit 2 (refused, not a false pass)"
  else
    echo "  FAIL  no --device → exit $rc (expected 2)"
    fails=$((fails + 1))
  fi
fi

# ─── added 2026-08-18, after the gate's FIRST hardware run ────────────────
# That run failed for 25 minutes on a device that had converged after 18, and
# every defect it found was in the GATE, not the device — three checks that
# could not do their job:
#
#   1. every serial read passed --shell ("assume already at a shell"), so on the
#      freshly booted console this gate exists to test, nothing was ever read,
#      and `2>/dev/null` turned that into "device never converged"
#   2. the promised byte-count verification called bare `blockdev`, absent from
#      PATH in a non-login shell on the bench, so only PIPESTATUS ever gated
#   3. the boot proof was `test -e <udev symlink>` and passed at t+6s from
#      power-on, on a leftover path — it could never fail. rc38 was structurally
#      perfect and unbootable; this check would have called it good.
#
# 2 is a pure string function and gets real fixtures. 1 and 3 need hardware to
# exercise end to end, so they get structural assertions — less than a live run,
# far more than a comment promising it was fixed.

check_eq() { # check_eq <got> <want> <label>
  ran=$((ran + 1))
  if [[ "$1" == "$2" ]]; then
    echo "  ok    $3"
  else
    echo "  FAIL  $3 — got '$1', wanted '$2'"
    fails=$((fails + 1))
  fi
}
check_true() { # check_true <0|1> <ok-label> <fail-label>
  ran=$((ran + 1))
  if [[ "$1" -eq 0 ]]; then echo "  ok    $2"; else echo "  FAIL  $3"; fails=$((fails + 1)); fi
}

echo "== byte count: the completeness half must actually parse =="
# The LIVE function, sourced out of the gate — never a copy. A selftest that
# re-declares the parser tests its own copy and stays green while the gate rots.
bw_src="$(sed -n '/^bytes_written() {/,/^}/p' "$GATE")"
if [[ -z "$bw_src" ]]; then
  echo "  FAIL  could not extract bytes_written() from the gate — fix the extraction, do not skip"
  fails=$((fails + 1)); ran=$((ran + 1))
else
  eval "$bw_src"
  check_eq "$(bytes_written '2621440000 bytes (2.6 GB, 2.4 GiB) copied, 138.2 s, 19.0 MB/s')" \
           "2621440000" "a real dd report yields its byte count"
  check_eq "$(bytes_written "$(printf '524288 bytes (524 kB) copied, 0.1 s\n2621440000 bytes (2.6 GB) copied, 138 s')")" \
           "2621440000" "the final total wins over progress lines"
  check_eq "$(bytes_written 'blockdev: command not found')" "" \
           "the exact 2026-08-18 output yields NOTHING, so the gate must refuse"
  check_eq "$(bytes_written '')" "" "no output yields nothing"
fi

echo "== structural: the three defects must not come back =="
grep -q 'serial_read()' "$GATE"; check_true $? \
  "the console reader handling BOTH login states is present" \
  "serial_read() is gone — reads would assume a logged-in console again"

grep -nE 'python3 .*BENCH_SERIAL_HELPER' "$GATE" | grep -q -- '--shell'
[[ $? -ne 0 ]]; check_true $? \
  "no serial read hard-codes --shell" \
  "a serial read passes --shell directly; on a fresh boot it reads nothing"

grep -q 'POWER_ON_EPOCH' "$GATE"; check_true $? \
  "the boot proof compares the device node against power-on time" \
  "the boot proof is back to bare existence — a stale symlink passes it"

grep -qE '^[[:space:]]*if ssh "\$BENCH" "test -e \$SERIAL_DEV"' "$GATE"
[[ $? -ne 0 ]]; check_true $? \
  "the boot proof is not bare existence on a udev symlink" \
  "the boot proof is test -e on a symlink again — it cannot fail"

# The precise invariant is "no BARE blockdev", not "an absolute path appears
# somewhere". The first spelling was an OR against lsblk, and re-introducing the
# bare call did not trip it, because the lsblk fallback was still in the file —
# the guard passed on a line that was not the one under test. Found by injecting.
grep -qE '(^|[^/[:alnum:]])blockdev ' "$GATE"
[[ $? -ne 0 ]]; check_true $? \
  "no bare blockdev call — every size read is absolute or via lsblk" \
  "a BARE blockdev call is back; it is not on PATH in a non-login shell on the bench, so the byte count dies silently"

grep -q 'WROTE_BYTES' "$GATE"; check_true $? \
  "the byte count is asserted, not merely printed" \
  "nothing asserts the byte count — the header promises a check that is absent"

if (( ran == 0 )); then
  echo "FATAL: nothing evaluated"
  exit 1
fi

echo
if (( fails == 0 )); then
  echo "provisioning-gate selftest: $ran/$ran expectations met"
  exit 0
fi
echo "provisioning-gate selftest: $fails of $ran expectations FAILED"
exit 1

