#!/usr/bin/env bash
# =============================================================================
# selftest.sh — a red device run must make the runner exit non-zero.
# =============================================================================
# tests/run_device_tests.sh ran the suites with
#     ssh … "sh /tmp/ga_tests/run_all.sh …" || true
# so the runner exited 0 whatever the device said. Measured on a canary pass:
# 3 failures, RC=0. Every caller that reads the exit code (a CI step, a bake
# gate, `tests/test-all.sh`, a person's `&& echo OK`) saw green.
#
# Two layers, both driven LIVE (no copy of either script):
#   DRX-01..06  the REAL runner, with a stub `ssh` on PATH whose remote
#               run_all.sh exits a chosen code. Nothing in the runner is mocked.
#   DRX-07..09  the REAL run_all.sh, on fixture suites in a temp tree. Its exit
#               code is a SUM of failures and a process status is 8 bits:
#               256 failures exited 0.
#
# must-fail (runner/run_all must go non-zero): remote 1, remote 3 (code kept),
# remote 2 (zero tests ran), 255 (ssh lost mid-run), 256 failures in one suite,
# 200+56 failures across two. must-pass: remote 0 -> runner 0; all-green
# fixture suites -> run_all 0. Cleanup and lock release must still happen on a
# red run — exiting early would strand the suites and the lock on the device.
#
# Needs bash + sh. No device. Exits 1 on any failure, 2 if fewer checks ran
# than expected.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RUNNER="$ROOT/tests/run_device_tests.sh"
RUN_ALL="$ROOT/tests/ga_tests/run_all.sh"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
fails=0; ran=0
check() {   # check <id> <description> <condition…>
  local id="$1" desc="$2"; shift 2
  ran=$((ran + 1))
  if "$@"; then printf '  %sok%s    %s  %s\n' "$GRN" "$NC" "$id" "$desc"
  else printf '  %sFAIL%s  %s  %s\n' "$RED" "$NC" "$id" "$desc"; fails=$((fails + 1)); fi
}

for f in "$RUNNER" "$RUN_ALL"; do
  [[ -f "$f" ]] || { echo "FATAL: $f missing — refusing to report a result"; exit 2; }
done

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/dev"

# The target is 198.51.100.9 — RFC 5737 TEST-NET-2, documentation only. This
# repository is public; a fixture address must be obviously nowhere.
#
# stub ssh — the last argument is the remote command, as the runner always
# calls it. run_all.sh exits $FAKE_RUN_RC; file operations are EVALUATED with
# the device's /tmp/ga_tests remapped into $FAKE_DEV, so the real lock and the
# real cleanup run against a real directory.
cat > "$W/bin/ssh" <<'STUB'
#!/bin/sh
last=""
for a in "$@"; do last="$a"; done
printf '%s\n' "$last" >> "$SSH_LOG"
case "$last" in
  *os-release*)  printf 'NAME="GA OS"\nVARIANT="iHost"\nGA_BUILD=1\n'; exit 0 ;;
  *run_all.sh*)  echo "RAN_SUITES rc=$FAKE_RUN_RC"; exit "$FAKE_RUN_RC" ;;
  *"tar xf"*)    cat >/dev/null; mkdir -p "$FAKE_DEV/ga_tests"; exit 0 ;;
  *"docker ps"*) exit 0 ;;
esac
eval "$(printf '%s' "$last" | sed "s#/tmp/ga_tests#$FAKE_DEV/ga_tests#g")"
STUB
chmod +x "$W/bin/ssh"

runner() {   # runner <remote-rc> -> $RC, $OUT, $LOG
  LOG="$W/ssh.$1.log"; : > "$LOG"
  rm -rf "$W/dev/ga_tests" "$W/dev/ga_tests.lock"
  OUT=$(FAKE_RUN_RC="$1" SSH_LOG="$LOG" FAKE_DEV="$W/dev" PATH="$W/bin:$PATH" \
        GA_TEST_RUN_OWNER="selftest@host" \
        bash "$RUNNER" --ssh root@198.51.100.9 --no-preflight 2>&1) && RC=0 || RC=$?
}
cleanup_after_run() {   # the rm -rf of the suites comes AFTER run_all.sh in the log
  awk '/run_all\.sh/{r=NR} /^rm -rf \/tmp\/ga_tests$/{if (r && NR > r) c=1} END{exit !c}' "$LOG"
}

echo "=== runner: MUST-FAIL (a red device run is a red runner) ==="
runner 1
check DRX-01a "remote run_all.sh exits 1 -> runner exits non-zero" [ "$RC" -ne 0 ]
check DRX-01b "…and the suites really ran (not an early refusal)" grep -q run_all.sh "$LOG"
check DRX-01c "…the suites are still cleaned off the device after the red run" cleanup_after_run
check DRX-01d "…and the run lock is still released" [ ! -d "$W/dev/ga_tests.lock" ]
check DRX-01e "…and the output says the run FAILED, with the code" \
  grep -q "run_all.sh exited 1" <<<"$OUT"
runner 3
check DRX-02 "remote exits 3 (three failures) -> runner exits 3, code kept" [ "$RC" -eq 3 ]
runner 2
check DRX-03 "remote exits 2 (zero tests ran) -> runner non-zero" [ "$RC" -ne 0 ]
runner 255
check DRX-04 "ssh lost mid-run (255) -> runner non-zero, never a pass" [ "$RC" -ne 0 ]

echo "=== runner: MUST-PASS (a green run stays green) ==="
runner 0
check DRX-05a "remote run_all.sh exits 0 -> runner exits 0" [ "$RC" -eq 0 ]
check DRX-05b "…and cleaned up" cleanup_after_run
check DRX-06 "…and released its lock" [ ! -d "$W/dev/ga_tests.lock" ]

# --- run_all.sh: the exit code is 8 bits, the failure count is not -----------
T="$W/tree"
mkdir -p "$T/lib"
cp "$RUN_ALL" "$T/run_all.sh"
cp "$ROOT/tests/ga_tests/lib/"*.sh "$T/lib/"
suite() {   # suite <name> <pass> <fail> — exits with its fail count, as suites do
  mkdir -p "$T/$1"
  printf '#!/bin/sh\necho "{\\"suite\\":\\"%s\\",\\"pass\\":%s,\\"fail\\":%s,\\"skip\\":0}"\nexit %s\n' \
    "$1" "$2" "$3" "$3" > "$T/$1/test.sh"
}
suite fx_green 5 0
suite fx_256 1 256
suite fx_200 1 200
suite fx_56 1 56
run_all() { GA_HA_PORT=80 sh "$T/run_all.sh" "$@" >"$W/run_all.out" 2>&1 && RA=0 || RA=$?; }

echo "=== run_all.sh: MUST-FAIL ==="
run_all fx_256
check DRX-07 "one suite with 256 failures (its own exit wrapped to 0) -> non-zero" [ "$RA" -ne 0 ]
run_all fx_200 fx_56
check DRX-08 "200 + 56 failures across two suites (sum 256) -> non-zero" [ "$RA" -ne 0 ]
echo "=== run_all.sh: MUST-PASS ==="
run_all fx_green
check DRX-09 "all fixture suites green -> exit 0" [ "$RA" -eq 0 ]

echo ""
echo "$ran checks, $fails failed"
EXPECTED=14
[[ "$ran" -ge "$EXPECTED" ]] || { echo "FATAL: only $ran of $EXPECTED checks ran"; exit 2; }
[[ "$fails" -eq 0 ]] || exit 1
echo "device runner exit selftest: all green"
