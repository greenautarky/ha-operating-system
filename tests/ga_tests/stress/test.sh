#!/bin/sh
# Stress / stability test suite - runs ON the device
# Uses stress-ng to verify system stability under load.
# Default timeout is 30s per test for automated runs.
# Set STRESS_TIMEOUT=300 (or higher) for thorough testing.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Stress"

T="${STRESS_TIMEOUT:-30}"
# stress-ng needs a writable temp directory (rootfs is read-only)
TP="/tmp"

# --- Prerequisites ---

if ! command -v stress-ng >/dev/null 2>&1; then
  skip_test "STRESS-01" "stress-ng is installed" "stress-ng not found"
  skip_test "STRESS-02" "CPU stress" "stress-ng not found"
  skip_test "STRESS-03" "Memory stress" "stress-ng not found"
  skip_test "STRESS-04" "Disk I/O stress" "stress-ng not found"
  skip_test "STRESS-05" "Combined stress" "stress-ng not found"
  skip_test "STRESS-06" "Thermal check under load" "stress-ng not found"
  skip_test "STRESS-07" "Service recovery after OOM pressure" "stress-ng not found"
  skip_test "STRESS-08" "Fork bomb resilience" "stress-ng not found"
  skip_test "STRESS-09" "Telemetry under CPU load" "stress-ng not found"
  skip_test "STRESS-10" "24h soak test" "stress-ng not found"
  # The overload injection does not use stress-ng — it spins a shell loop in a
  # throwaway container — but it belongs to this suite's count either way, and
  # a suite that silently omits three tests reports a smaller total, not a
  # failure.
  skip_test "STRESS-11" "ga_manager reports the container.cpu_load check" "suite aborted early"
  skip_test "STRESS-12" "a container burning a core is reported as overload" "suite aborted early"
  skip_test "STRESS-13" "nothing is reported as overload once the load is gone" "suite aborted early"
  suite_end
  exit 0
fi

run_test "STRESS-01" "stress-ng is installed" \
  "stress-ng --version >/dev/null 2>&1"

# --- CPU stress ---
# Split, because the old assertion bundled an unrelated precondition: it
# required telegraf AND fluent-bit to be active AFTER the stress run. Those need
# provisioning credentials, so on an unprovisioned device STRESS-02 failed while
# saying "CPU stress" — attributing a missing credential to the CPU test.
# Measured on K31 2026-07-30: stress-ng ran fine, both services were inactive.
run_test "STRESS-02" "CPU stress — all cores (${T}s) survives" \
  "stress-ng --temp-path ${TP} --cpu 0 --cpu-method matrixprod --timeout ${T} --metrics-brief >/dev/null 2>&1"

# The telemetry half is the interesting one on a PROVISIONED device — do the
# collectors survive full CPU load — so it is kept, as its own claim, and skipped
# rather than failed where those services are not configured yet.
if systemctl is-active telegraf >/dev/null 2>&1 || systemctl is-active fluent-bit >/dev/null 2>&1; then
  run_test "STRESS-02b" "telemetry collectors still active after CPU stress" \
    "systemctl is-active telegraf >/dev/null 2>&1 && systemctl is-active fluent-bit >/dev/null 2>&1"
else
  skip_test "STRESS-02b" "telemetry collectors after CPU stress" "telegraf/fluent-bit not active — unprovisioned device, no credentials yet"
fi

# --- Memory stress ---
run_test "STRESS-03" "Memory stress — 80% RAM (${T}s)" \
  "stress-ng --temp-path ${TP} --vm 2 --vm-bytes 80% --vm-method all --timeout ${T} --metrics-brief >/dev/null 2>&1 && ! journalctl -b 0 --no-pager -q 2>/dev/null | grep -qi 'oom.*telegraf\|oom.*fluent'"

# --- Disk I/O stress ---
run_test "STRESS-04" "Disk I/O stress — sustained writes (${T}s)" \
  "stress-ng --temp-path /mnt/data --hdd 2 --hdd-bytes 64M --timeout ${T} --metrics-brief >/dev/null 2>&1 && test -w /mnt/data"

# --- Combined stress ---
# TODO: Improve combined stress resilience (cgroup tuning, memory limits)
warn_test "STRESS-05" "Combined CPU+memory+I/O stress (${T}s)" \
  "stress-ng --temp-path /mnt/data --cpu 2 --vm 1 --vm-bytes 60% --hdd 1 --hdd-bytes 64M --timeout ${T} --metrics-brief >/dev/null 2>&1 && systemctl is-active telegraf >/dev/null 2>&1 && systemctl is-active fluent-bit >/dev/null 2>&1"

# --- Thermal check ---
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
  run_test "STRESS-06" "Thermal stays below 85C under CPU load" \
    "stress-ng --temp-path ${TP} --cpu 0 --timeout ${T} >/dev/null 2>&1 & PID=\$!; MAX=0; for i in 1 2 3 4 5; do sleep \$((T/5)); TEMP=\$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0); [ \"\$TEMP\" -gt \"\$MAX\" ] && MAX=\$TEMP; done; wait \$PID 2>/dev/null; [ \"\$MAX\" -lt 85000 ]"
else
  skip_test "STRESS-06" "Thermal check under load" "no thermal_zone0 sysfs"
fi

# --- OOM pressure + recovery ---
# TODO: Add OOMScoreAdjust=-900 to telegraf/fluent-bit service units
warn_test "STRESS-07" "Services survive OOM pressure" \
  "stress-ng --temp-path ${TP} --vm 4 --vm-bytes 95% --timeout 15 >/dev/null 2>&1; sleep 5; systemctl is-active telegraf >/dev/null 2>&1 && systemctl is-active fluent-bit >/dev/null 2>&1"

# TODO: Add TasksMax= limit to system slice or DefaultTasksMax in logind.conf
warn_test "STRESS-08" "Fork bomb resilience (${T}s)" \
  "stress-ng --temp-path ${TP} --fork 4 --timeout ${T} --metrics-brief >/dev/null 2>&1; systemctl is-active telegraf >/dev/null 2>&1"

# --- Network under load ---
run_test "STRESS-09" "Telemetry flows under CPU load" \
  "stress-ng --temp-path ${TP} --cpu 0 --timeout ${T} >/dev/null 2>&1 & PID=\$!; sleep \$((T > 10 ? 10 : T)); OK=\$(! journalctl -u telegraf --since '30 sec ago' --no-pager -q 2>/dev/null | grep -qi 'timeout\|connection refused' && echo yes || echo no); wait \$PID 2>/dev/null; [ \"\$OK\" = 'yes' ]"

# --- 24h soak (always manual) ---
skip_test "STRESS-10" "24h soak test" "run manually: STRESS_TIMEOUT=86400 stress-ng --cpu 1 --vm 1 --vm-bytes 30%"

# ─── Failure injection: sustained container overload ──────────────────────────
#
# The container health check reported up or down. A container that is up and
# burning a core read exactly like a healthy one — which is how one add-on sat
# at roughly a fifth of a core on a canary for weeks with nothing noticing.
# ga_manager 0.159.0 added `container.cpu_load`, and a guard that has never
# been made to fire is not a guard. So: put a real sustained load on a real
# container and require the device to say so.
#
# The load goes into a THROWAWAY container, never a production one. It appears
# in exactly the same cgroup counters the check reads, and removing it cannot
# hurt anything.
#
# STRESS-13 is the half that keeps this honest: with the load gone, nothing may
# be reported as overloaded. A check that says "overload" for everything is as
# useless as one that never says it, and only the pair proves neither.

GM_C=$(docker ps -q --filter name=ga_manager 2>/dev/null | head -1)
INJ_NAME="ga-overload-injection"
# The collector is invoked by path so the test does not wait out its two-minute
# timer twice. Overridable so a collector under development can be proven on a
# device whose read-only rootfs still carries the previous one.
HOST_STATS_BIN="${GA_HOST_STATS_BIN:-/usr/libexec/ga-host-stats}"

gm_health() {
  [ -n "$GM_C" ] || return 1
  docker exec "$GM_C" sh -c \
    'curl -sS -m 10 -H "Authorization: Bearer $(cat /data/auth.token)" http://127.0.0.1:8099/health' \
    2>/dev/null
}

# jq on the iHost has no oniguruma, so no test/match/sub — plain field access only.
cpu_load_row() { # cpu_load_row <container-name> <field>
  gm_health | jq -r --arg n "$1" --arg f "$2" \
    '[.checks[]? | select(.name=="container.cpu_load") | .details.containers[]?
      | select(.name==$n) | .[$f]] | first // "absent"' 2>/dev/null
}

overloaded_count() {
  gm_health | jq -r \
    '[.checks[]? | select(.name=="container.cpu_load") | .details.containers[]?
      | select(.load=="overload")] | length' 2>/dev/null
}

cleanup_injection() {
  docker rm -f "$INJ_NAME" >/dev/null 2>&1 || true
}
trap cleanup_injection EXIT INT TERM

if [ -z "$GM_C" ]; then
  skip_test "STRESS-11" "ga_manager reports container.cpu_load" "ga_manager container not running"
  skip_test "STRESS-12" "a container burning a core is reported as overload" "ga_manager container not running"
  skip_test "STRESS-13" "nothing is reported as overload once the load is gone" "ga_manager container not running"
else
  HAS_CHECK=$(gm_health | jq -r '[.checks[]? | select(.name=="container.cpu_load")] | length' 2>/dev/null)
  run_test "STRESS-11" "ga_manager reports the container.cpu_load check" \
    "[ \"${HAS_CHECK:-0}\" -ge 1 ]"

  if [ "${HAS_CHECK:-0}" -lt 1 ]; then
    skip_test "STRESS-12" "a container burning a core is reported as overload" \
      "device runs a ga_manager older than 0.159.0"
    skip_test "STRESS-13" "nothing is reported as overload once the load is gone" \
      "device runs a ga_manager older than 0.159.0"
  else
    # Reuse an image that is already on the device — a pull would make this
    # test depend on registry reachability, which is not what it is testing.
    INJ_IMAGE=$(docker inspect --format '{{.Config.Image}}' "$GM_C" 2>/dev/null)
    cleanup_injection
    docker run -d --name "$INJ_NAME" --entrypoint sh "$INJ_IMAGE" \
      -c 'while :; do :; done' >/dev/null 2>&1

    # Two host snapshots are the minimum: one counter reading is not a rate.
    # The collector is invoked directly so the test does not wait out its
    # two-minute timer twice.
    INJ_SEEN=no
    INJ_PCT=0
    i=0
    while [ "$i" -lt 20 ]; do
      "$HOST_STATS_BIN" >/dev/null 2>&1
      sleep 15
      LOAD=$(cpu_load_row "$INJ_NAME" load)
      if [ "$LOAD" = "overload" ]; then
        INJ_SEEN=yes
        INJ_PCT=$(cpu_load_row "$INJ_NAME" cpu_core_pct)
        break
      fi
      i=$((i+1))
    done

    run_test_show "STRESS-12" \
      "a container burning a core is reported as overload (measured ${INJ_PCT}% of one core)" \
      "[ \"$INJ_SEEN\" = yes ]"

    cleanup_injection

    # And back down. Without this half, a check hard-wired to "overload" would
    # pass STRESS-12 and prove nothing.
    REST_OK=no
    i=0
    while [ "$i" -lt 20 ]; do
      "$HOST_STATS_BIN" >/dev/null 2>&1
      sleep 15
      N=$(overloaded_count)
      if [ "${N:-1}" = "0" ]; then REST_OK=yes; break; fi
      i=$((i+1))
    done
    run_test_show "STRESS-13" \
      "nothing is reported as overload once the injected load is gone" \
      "[ \"$REST_OK\" = yes ]"
  fi
fi
trap - EXIT INT TERM
cleanup_injection

suite_end
