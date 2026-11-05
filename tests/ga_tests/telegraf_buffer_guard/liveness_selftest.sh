#!/bin/bash
# Host selftest for the TGW-02/TGW-03 liveness helpers of test.sh.
#
# TGW-03 could never pass on a device: it computed telegraf's uptime with
# `date -d "$(systemctl show -p ActiveEnterTimestamp ...)"`, and busybox date
# rejects systemd's format ("Wed 2026-11-04 15:59:25 CET" -> invalid date), so
# the uptime fell back to 0. Measured twice on the bench board.
#
# This runs the LIVE helper functions, extracted from test.sh by name, under
# busybox sh with busybox date first in PATH. Only systemctl, journalctl and
# /proc/uptime are stubbed (they are the inputs); the helpers are never copied.
# Fixtures use the REAL strings measured on devices.
#
# Usage: tests/ga_tests/telegraf_buffer_guard/liveness_selftest.sh [path/to/test.sh]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="${1:-$HERE/test.sh}"
command -v busybox >/dev/null || { echo "FAIL: busybox not installed - cannot run the device-shell selftest"; exit 2; }
[ -f "$SUITE" ] || { echo "FAIL: $SUITE not found"; exit 2; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
# Extract every helper the liveness checks use, by name, from the LIVE file.
# A one-liner ends on its header line; a block ends at the first column-0 "}".
awk 'f { print; if ($0 ~ /^}/) f=0; next }
     /^(tg_[a-z_]+|deliver_ok|no_bad_lines)\(\) *\{/ { print; if ($0 !~ /\} *$/) f=1 }' "$SUITE" > "$W/helpers.sh"
n="$(grep -cE '^(tg_[a-z_]+|deliver_ok|no_bad_lines)\(\)' "$W/helpers.sh")"
[ "$n" -ge 2 ] || { echo "FAIL: extracted $n helper(s) from $SUITE - extraction broken"; exit 2; }
grep -q '^deliver_ok()' "$W/helpers.sh" || { echo "FAIL: deliver_ok not found in $SUITE"; exit 2; }

ln -s "$(command -v busybox)" "$W/bin/date"
ln -s "$(command -v busybox)" "$W/bin/cut"
ln -s "$(command -v busybox)" "$W/bin/grep"
cat > "$W/bin/systemctl" <<'EOF'
#!/bin/sh
# systemctl show -p <Prop> --value telegraf  ->  $FX/<Prop>
p=""; while [ $# -gt 0 ]; do [ "$1" = -p ] && p="$2"; shift; done
cat "$FX/$p" 2>/dev/null
EOF
cat > "$W/bin/journalctl" <<'EOF'
#!/bin/sh
# Only the current run's journal exists, and only when selected by its
# InvocationID (old code asked with -u/--since: also answered, like the device).
for a in "$@"; do
  case "$a" in _SYSTEMD_INVOCATION_ID=*) [ "${a#*=}" = "$(cat "$FX/InvocationID" 2>/dev/null)" ] || exit 0 ;; esac
done
cat "$FX/journal" 2>/dev/null
EOF
chmod +x "$W/bin/systemctl" "$W/bin/journalctl"

PASS=0 FAIL=0
okk() { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

# fx <name> <ActiveEnterTimestamp> <Monotonic us> <uptime s> <InvocationID> <journal text>
fx() {
  local d="$W/$1"; mkdir -p "$d"
  printf '%s\n' "$2" > "$d/ActiveEnterTimestamp"
  printf '%s\n' "$3" > "$d/ActiveEnterTimestampMonotonic"
  printf '%s.28 42045.51\n' "$4" > "$d/uptime"   # real /proc/uptime shape
  printf '%s\n' "$5" > "$d/InvocationID"
  printf '%s\n' "$6" > "$d/journal"
}
# expect <name> <function> <0|1>
expect() {
  local rc
  FX="$W/$1" PROC_UPTIME="$W/$1/uptime" PATH="$W/bin:/usr/bin:/bin" \
    busybox sh -c ". '$W/helpers.sh'; $2" > "$W/out.$1.$2" 2>&1; rc=$?
  [ "$rc" -ne 0 ] && rc=1
  if [ "$rc" = "$3" ]; then okk "$1: $2 -> rc $rc"; else bad "$1: $2 -> rc $rc (want $3)"; sed 's/^/        | /' "$W/out.$1.$2"; fi
}

REAL_TS="Wed 2026-11-04 15:59:25 CET"     # verbatim from the bench device
INV=1b6512b15a0942b39076740f5e6e9ab4
QUIET="2026-11-04T15:59:26Z I! Loaded outputs: influxdb"

echo "TGW-03 deliver_ok (live helpers, busybox sh + busybox date):"
# up 45 s (real device values: mono 45376443 us at uptime 90) -> deliver
fx up45-real-ts "$REAL_TS" 45376443 90 "$INV" "$QUIET";              expect up45-real-ts deliver_ok 0
# us value beyond 2^31 (unit started after ~36 min of uptime): up 100 s -> deliver
fx up100-big-us "$REAL_TS" 12000000000 12100 "$INV" "$QUIET";        expect up100-big-us deliver_ok 0
# up only 10 s and no "Wrote batch" -> not yet proven
fx up10 "$REAL_TS" 45376443 55 "$INV" "$QUIET";                       expect up10 deliver_ok 1
# write error in the current run -> not delivering
fx write-error "$REAL_TS" 45376443 900 "$INV" "2026-11-04T16:00:00Z E! [agent] Error writing to outputs.influxdb: timeout"
expect write-error deliver_ok 1
# "Wrote batch" (debug) present -> delivers regardless of uptime
fx wrote-batch "$REAL_TS" 45376443 50 "$INV" "2026-11-04T15:59:30Z D! [outputs.influxdb] Wrote batch of 12 metrics in 20ms"
expect wrote-batch deliver_ok 0
# current run unknown (no InvocationID) -> must FAIL, never pass on an empty journal
fx no-invocation "$REAL_TS" 45376443 900 "" "$QUIET";                expect no-invocation deliver_ok 1

if grep -q '^no_bad_lines()' "$W/helpers.sh"; then
  echo "TGW-02 no_bad_lines:"
  expect up45-real-ts no_bad_lines 0
  fx panic "$REAL_TS" 45376443 900 "$INV" "panic: failed to open wal file: log corrupt"; expect panic no_bad_lines 1
  expect no-invocation no_bad_lines 1
  # exact value: the helper must report 100 s for the beyond-2^31 fixture
  v="$(FX="$W/up100-big-us" PROC_UPTIME="$W/up100-big-us/uptime" PATH="$W/bin:/usr/bin:/bin" busybox sh -c ". '$W/helpers.sh'; tg_up_s" 2>/dev/null)"
  [ "$v" = 100 ] && okk "tg_up_s = 100 s for a us value beyond 2^31" || bad "tg_up_s = '$v' (want 100)"
else
  bad "no_bad_lines() missing - TGW-02 can pass on an empty journal"
fi

echo "static (the device shell is 32-bit, which this host shell cannot reproduce):"
if grep -qE 'date -d' "$W/helpers.sh"; then bad "helpers parse dates with 'date -d' (busybox rejects systemd timestamps)"; else okk "no 'date -d' in the helpers"; fi
if grep -E '\$\(\(' "$W/helpers.sh" | grep -qE '_mono|Monotonic'; then bad "microsecond value used inside \$(( )) - overflows 2^31 on armv7"; else okk "microsecond value never enters \$(( ))"; fi

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] && [ "$PASS" -ge 8 ] && { echo "PASS: TGW-02/03 helpers work with the device's real strings"; exit 0; }
exit 1
