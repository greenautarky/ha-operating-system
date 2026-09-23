#!/bin/sh
# run_device_tests.sh refuses a second run against the same device — host-side.
#
# WHY: the runner's first act against a device is `rm -rf /tmp/ga_tests`, so a
# second run deletes the suites out from under the first one MID-RUN. On
# 2026-09-23 an overlapping run reported 220 passed / 18 failed where the same
# device alone reported 463 / 5. Eighteen failures about the measurement, inside
# a report whose purpose was to judge the device.
#
# This drives the REAL tests/run_device_tests.sh with a stub `ssh` on PATH and a
# directory standing in for the device's /tmp. Nothing inside the runner is
# mocked: the lock command, the ordering against the destructive step, the
# ownership check on release and the takeover ceiling are all the shipped code.
#
#   DRL-01  MUST NOT BLOCK: an ordinary single run acquires, runs, releases
#   DRL-02  a second run against a locked device refuses with exit 3
#   DRL-03  …and names who holds it and how old it is
#   DRL-04  …and refuses BEFORE the rm -rf — the destructive step never happens
#   DRL-05  a lock past the staleness ceiling is taken over, LOUDLY
#   DRL-06  --force-unlock clears a fresh lock
#   DRL-07  a lock another run took over is NOT deleted when this one finishes
#
# Needs bash + sh. No device.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "device run lock (run_device_tests.sh)"

RUNNER="$SCRIPT_DIR/../../run_device_tests.sh"
run_test "DRL-00" "the runner is where this suite drives it" "test -x '$RUNNER'"
[ -x "$RUNNER" ] || { suite_end; exit 1; }

W="$(mktemp -d 2>/dev/null || echo /tmp/drl_$$)"
mkdir -p "$W/bin" "$W/dev"

# The target is 198.51.100.9 — RFC 5737 TEST-NET-2, reserved for documentation.
# Not an RFC1918 address: this repository is public and the disclosure gate flags
# 10/8, 172.16/12, 192.168/16 and the mesh range in added lines, correctly. A
# fixture needs an address that is obviously nowhere, not one that could be a
# real device.
#
# stub ssh — the last argument is the remote command, as the runner always calls
# it. Everything the runner asks of a device that is not a file operation is
# answered here; file operations are EVALUATED, with the device's /tmp/ga_tests
# remapped into $FAKE_DEV, so the real lock logic really runs.
cat > "$W/bin/ssh" <<'STUB'
#!/bin/sh
last=""
for a in "$@"; do last="$a"; done
printf '%s\n' "$last" >> "$SSH_LOG"
case "$last" in
  *os-release*)  printf 'NAME="GA OS"\nVARIANT="iHost"\nGA_BUILD=1\n'; exit 0 ;;
  *run_all.sh*)  echo "RAN_SUITES"; exit 0 ;;
  *"tar xf"*)    cat >/dev/null; exit 0 ;;
  *"docker ps"*) exit 0 ;;
  *ga-release*)  printf '%s\n' "${FAKE_RELEASE:-unknown}"; exit 0 ;;
esac
eval "$(printf '%s' "$last" | sed "s#/tmp/ga_tests#$FAKE_DEV/ga_tests#g")"
STUB
chmod +x "$W/bin/ssh"

LOCK="$W/dev/ga_tests.lock"

runner() {   # runner <logname> -> exit code in $RC, output in $OUT, ssh log in $LOG
  LOG="$W/$1.ssh.log"; : > "$LOG"
  OUT=$(SSH_LOG="$LOG" FAKE_DEV="$W/dev" PATH="$W/bin:$PATH" \
        GA_TEST_RUN_OWNER="${2:-tester@laptop}" \
        bash "$RUNNER" --ssh root@198.51.100.9 --no-preflight ${3:-} 2>&1) && RC=0 || RC=$?
}

# plant a lock as another run would have left it: <age-in-seconds> <owner>
plant_lock() {
  rm -rf "$LOCK"; mkdir -p "$LOCK"
  { echo "owner=$2"; echo "started=2026-09-23T06:00:00Z"; echo "epoch=$(( $(date +%s) - $1 ))"; } > "$LOCK/stamp"
}

# --- DRL-01 — must not block -------------------------------------------------
rm -rf "$LOCK"
runner single
run_test "DRL-01a" "MUST NOT BLOCK: an ordinary single run completes (exit 0)" "[ '$RC' = 0 ]"
run_test "DRL-01b" "MUST NOT BLOCK: …and it really ran the suites" \
  "grep -q RAN_SUITES '$W/single.ssh.log' || printf '%s' \"\$OUT\" | grep -q RAN_SUITES"
run_test "DRL-01c" "the lock is released when the run finishes" "[ ! -d '$LOCK' ]"

# --- DRL-02..04 — the refusal ------------------------------------------------
plant_lock 120 "ci@ga-builder"
runner second
run_test "DRL-02" "a second run against a locked device refuses with exit 3" "[ '$RC' = 3 ]"
OUT_SECOND="$OUT"
run_test "DRL-03a" "the refusal names the holder" \
  "printf '%s' \"\$OUT_SECOND\" | grep -q 'ci@ga-builder'"
run_test "DRL-03b" "the refusal names the age, so 'wait' is an informed choice" \
  "printf '%s' \"\$OUT_SECOND\" | grep -qE '\\(1[0-9][0-9]s ago\\)'"
run_test "DRL-03c" "the refusal names the way out" \
  "printf '%s' \"\$OUT_SECOND\" | grep -q -- '--force-unlock'"
# The one that matters: the destructive step must not have happened.
run_test "DRL-04a" "it refuses BEFORE the rm -rf — the suites are not deleted" \
  "! grep -q 'rm -rf /tmp/ga_tests\$' '$W/second.ssh.log'"
run_test "DRL-04b" "…and before shipping or running anything" \
  "! grep -qE 'tar xf|run_all.sh' '$W/second.ssh.log'"
run_test "DRL-04c" "the other run's lock is left exactly as it was" \
  "grep -qx 'owner=ci@ga-builder' '$LOCK/stamp'"

# --- DRL-05 — the stale takeover, loudly -------------------------------------
plant_lock 7200 "ci@ga-builder"
runner stale
run_test "DRL-05a" "a lock past the ceiling is taken over (exit 0)" "[ '$RC' = 0 ]"
OUT_STALE="$OUT"
run_test "DRL-05b" "the takeover is announced at WARNING, with the age" \
  "printf '%s' \"\$OUT_STALE\" | grep -q 'WARNING: taking over a run lock that is 7[0-9][0-9][0-9]s old'"
run_test "DRL-05c" "…and says what it means if that run is NOT dead" \
  "printf '%s' \"\$OUT_STALE\" | grep -q 'both reports are worthless'"

# --- DRL-06 — --force-unlock --------------------------------------------------
plant_lock 60 "ci@ga-builder"
runner forced "tester@laptop" "--force-unlock"
run_test "DRL-06" "--force-unlock clears a fresh lock and the run proceeds" "[ '$RC' = 0 ]"

# --- DRL-07 — release must not delete a lock that is no longer ours ----------
# A run whose lock was taken over as stale must not, on finishing, delete the NEW
# owner's lock — that would open the door for a third run behind it.
#
# The first version of this raced: it started the runner in the background, polled
# for the stamp, and rewrote it. That passed here and FAILED in CI, because the
# whole stubbed run finishes in milliseconds and `sleep 0.05` is not portable. A
# test that depends on winning a race tells you about the race, not the rule.
#
# So the STUB does the stealing, at a point the runner itself defines: the moment
# it ships the suites, the lock changes hands. No timing, no polling.
rm -rf "$LOCK"
cat > "$W/bin/ssh" <<'STUB2'
#!/bin/sh
last=""
for a in "$@"; do last="$a"; done
printf '%s\n' "$last" >> "$SSH_LOG"
case "$last" in
  *os-release*)  printf 'NAME="GA OS"\nVARIANT="iHost"\nGA_BUILD=1\n'; exit 0 ;;
  *run_all.sh*)  echo "RAN_SUITES"; exit 0 ;;
  *"tar xf"*)
      cat >/dev/null
      # another run takes the lock over, right here
      { echo 'owner=other@runner'; echo 'started=now'; echo "epoch=$(date +%s)"; } \
        > "$FAKE_DEV/ga_tests.lock/stamp"
      exit 0 ;;
  *"docker ps"*) exit 0 ;;
esac
eval "$(printf '%s' "$last" | sed "s#/tmp/ga_tests#$FAKE_DEV/ga_tests#g")"
STUB2
chmod +x "$W/bin/ssh"
runner handover
run_test "DRL-07a" "a lock taken over by another run survives this run's release" \
  "test -f '$LOCK/stamp' && grep -qx 'owner=other@runner' '$LOCK/stamp'"
run_test "DRL-07b" "…and the run itself still finished normally" "[ '$RC' = 0 ]"

rm -rf "$W"
suite_end
