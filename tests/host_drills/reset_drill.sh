#!/usr/bin/env bash
# =============================================================================
# reset_drill.sh - HOST-SIDE reset drill: does each crash-evidence mechanism
# really fire after an unclean reset, and stay silent after a clean reboot?
# =============================================================================
# DESTRUCTIVE: reboots the device. Run it on a bench canary (K31), never on a
# customer device. It refuses to run without --i-know-this-reboots-the-device.
#
# WHY
#   A field device logged 12 unclean boots; the journal line never reached Loki
#   and the failure-trail dump was empty. Nothing had ever driven the whole
#   chain on a real device, so each mechanism could be broken independently and
#   look fine. This drill resets the device the hard way, waits for it, and
#   asserts EACH mechanism with its own message.
#
# MODES
#   unclean  `echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger`
#            = immediate reboot without sync/unmount. (a)-(f) must all fire.
#   clean    `systemctl reboot`. (a)-(c) and the unclean-dump must NOT fire
#            (must-not-flag counterpart: a drill that always says "unclean"
#            would be a decoration).
#
# ASSERTIONS (each is its own PASS/FAIL/SKIP line)
#   a  /mnt/data/crash_history.log gained an entry (clean: unchanged)
#   b  ga-boot-check logged UNCLEAN SHUTDOWN DETECTED in THIS boot's journal
#      (clean: it did not)
#   c  /mnt/data/supervisor/share/.ga_last_boot_unclean exists (clean: absent)
#   d  a non-empty, readable journal dump from ga-boot-check exists - only if the
#      image has /usr/libexec/ga-journal-dump (clean: no bootcheck-unclean dump)
#   e  telegraf.service is active. Label [owner: telegraf WAL] - a failure here
#      belongs to the telegraf stream, not to the mechanisms above.
#   f  the UNCLEAN line is queryable in Loki for this device within
#      LOKI_WAIT_MIN minutes (clean: no such line since the drill started).
#      NEEDS: LOKI_QUERY_URL (e.g. https://host/loki), optional LOKI_USER /
#      LOKI_PASSWORD / LOKI_TENANT, and a device with the tier-1 shipper
#      (fluent-bit.service) active - tier-0 does not carry ga-boot-check lines.
#      Without them (f) is reported SKIP "not covered", never faked.
#
# EXIT  0 all executed assertions passed (SKIPs are listed, not hidden)
#       1 at least one assertion failed
#       2 the drill itself could not run (precondition, timeout) - never green
#
# USAGE
#   tests/host_drills/reset_drill.sh --ssh root@<device> [--port 22222] \
#       [--key PATH] --mode unclean|clean --i-know-this-reboots-the-device \
#       [--require-consent]
#   --require-consent  for the run that must PROVE (e) and (f): a missing consent
#                      marker, an unset LOKI_QUERY_URL or an inactive shipper is
#                      a FAIL instead of a SKIP. (e) is gated by
#                      /mnt/data/.ga-consent-metrics, (f) by .ga-consent-error_logs.
# =============================================================================
set -uo pipefail

SSH_PORT="${SSH_PORT:-22222}"
SSH_KEY="${SSH_KEY:-}"
TARGET="" MODE="" CONFIRM=0
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
SETTLE_TIMEOUT="${SETTLE_TIMEOUT:-180}"
LOKI_WAIT_MIN="${LOKI_WAIT_MIN:-10}"
POLL="${POLL:-3}"
TRIGGER_WAIT="${TRIGGER_WAIT:-2}"
CLEAN_LOKI_WAIT="${CLEAN_LOKI_WAIT:-60}"
# --require-consent (or REQUIRE_CONSENT=1): the run that must prove (e) and (f).
# Without it, a device without telemetry consent SKIPs (e)/(f) - telegraf and the
# tier-1 shipper are gated off BY DESIGN there, so red would be red for the wrong
# reason. With it, every reason to skip (e)/(f) is a FAIL: no escape hatch.
REQUIRE_CONSENT="${REQUIRE_CONSENT:-0}"

while [ $# -gt 0 ]; do
    case "$1" in
        --ssh) TARGET="$2"; shift 2 ;;
        --port) SSH_PORT="$2"; shift 2 ;;
        --key) SSH_KEY="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --i-know-this-reboots-the-device) CONFIRM=1; shift ;;
        --require-consent) REQUIRE_CONSENT=1; shift ;;
        -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$TARGET" ] || { echo "ERROR: --ssh user@host required" >&2; exit 2; }
case "$MODE" in unclean|clean) ;; *) echo "ERROR: --mode unclean|clean required" >&2; exit 2 ;; esac
[ "$CONFIRM" = 1 ] || { echo "ERROR: this drill REBOOTS the device; pass --i-know-this-reboots-the-device" >&2; exit 2; }

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR -o Port=$SSH_PORT"
[ -n "$SSH_KEY" ] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"

# rsh <name> <command> - run on the device; <name> tags the call (host-test seam)
rsh() {
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$TARGET" "# $1
$2" 2>/dev/null
}

PASS=0 FAIL=0 SKIP=0
ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  SKIP  %s\n' "$1"; }
abort() { echo "DRILL ABORTED (not a verdict): $*" >&2; exit 2; }

echo "=== Reset drill ($MODE) ==="

# --- preconditions -----------------------------------------------------------
rsh ping 'echo OK' | grep -q OK || abort "device not reachable"
BOOT_BEFORE="$(rsh boot_id 'cat /proc/sys/kernel/random/boot_id' | tr -d '[:space:]')"
[ -n "$BOOT_BEFORE" ] || abort "cannot read boot_id"
CRASH_BEFORE="$(rsh crash_count 'wc -l < /mnt/data/crash_history.log 2>/dev/null || echo 0' | tr -d '[:space:]')"
case "$CRASH_BEFORE" in ''|*[!0-9]*) abort "cannot read crash_history.log line count ('$CRASH_BEFORE')" ;; esac
# the live marker is what makes the NEXT boot detect an unclean stop
rsh marker 'test -f /mnt/data/.ga_unclean_shutdown && echo MARKER' | grep -q MARKER \
    || abort "/mnt/data/.ga_unclean_shutdown absent before the reset - ga-crash-marker has not run, the drill would prove nothing"
START_EPOCH="$(rsh epoch 'date +%s' | tr -d '[:space:]')"
case "$START_EPOCH" in ''|*[!0-9]*) abort "cannot read device time" ;; esac
# The label fluent-bit stamps on every Loki stream: DEVICE_LABEL in the env file
# ga-fluent-bit-env writes (there is no /mnt/data/ga-device-label on any device).
LABEL_FILE=/mnt/data/fluent-bit/env
LABEL="$(rsh label "sed -n 's/^DEVICE_LABEL=//p' $LABEL_FILE 2>/dev/null | head -1" | tr -d '[:space:]"'"'"'')"
HAS_DUMP="$(rsh has_dump 'test -x /usr/libexec/ga-journal-dump && echo yes || echo no' | tr -d '[:space:]')"
T1_ACTIVE="$(rsh tier1 'systemctl is-active fluent-bit.service 2>/dev/null' | tr -d '[:space:]')"
echo "  before: boot_id=${BOOT_BEFORE:0:8} crash_log_lines=$CRASH_BEFORE journal_dump_in_image=$HAS_DUMP tier1_shipper=${T1_ACTIVE:-unknown}"

# --- the reset ---------------------------------------------------------------
if [ "$MODE" = unclean ]; then
    echo "  triggering UNCLEAN reset (sysrq b: no sync, no unmount)..."
    rsh trigger_unclean 'echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger' >/dev/null &
else
    echo "  triggering CLEAN reboot (systemctl reboot)..."
    rsh trigger_clean 'systemctl reboot' >/dev/null &
fi
TRIG_PID=$!
sleep "$TRIGGER_WAIT"
kill "$TRIG_PID" 2>/dev/null || true
wait "$TRIG_PID" 2>/dev/null || true

# --- wait for the NEW boot (a different boot_id, not merely "ssh answers") ----
echo "  waiting for the device (new boot_id)..."
waited=0 BOOT_AFTER=""
while [ "$waited" -lt "$BOOT_TIMEOUT" ]; do
    sleep "$POLL"; waited=$((waited + POLL))
    BOOT_AFTER="$(rsh boot_id 'cat /proc/sys/kernel/random/boot_id' | tr -d '[:space:]')"
    [ -n "$BOOT_AFTER" ] && [ "$BOOT_AFTER" != "$BOOT_BEFORE" ] && break
    BOOT_AFTER=""
done
[ -n "$BOOT_AFTER" ] || abort "device did not come back with a new boot_id within ${BOOT_TIMEOUT}s"

# ga-boot-check is a oneshot in sysinit; wait until it has finished
waited=0 st=""
while [ "$waited" -lt "$SETTLE_TIMEOUT" ]; do
    st="$(rsh bootcheck_state 'systemctl show -p ActiveState --value ga-boot-check.service' | tr -d '[:space:]')"
    case "$st" in active|inactive|failed) break ;; esac
    sleep "$POLL"; waited=$((waited + POLL))
done
echo "  after: boot_id=${BOOT_AFTER:0:8} ga-boot-check=$st"

# --- a: crash_history.log ----------------------------------------------------
CRASH_AFTER="$(rsh crash_count 'wc -l < /mnt/data/crash_history.log 2>/dev/null || echo 0' | tr -d '[:space:]')"
if [ "$MODE" = unclean ]; then
    if [ "${CRASH_AFTER:-0}" -gt "$CRASH_BEFORE" ] 2>/dev/null; then ok "(a) crash_history.log gained an entry ($CRASH_BEFORE -> $CRASH_AFTER lines)"
    else bad "(a) crash_history.log did NOT gain an entry ($CRASH_BEFORE -> ${CRASH_AFTER:-?} lines)"; fi
else
    if [ "${CRASH_AFTER:-0}" -eq "$CRASH_BEFORE" ] 2>/dev/null; then ok "(a) clean reboot: crash_history.log unchanged ($CRASH_AFTER lines)"
    else bad "(a) clean reboot WRONGLY logged a crash ($CRASH_BEFORE -> ${CRASH_AFTER:-?} lines)"; fi
fi

# --- b: ga-boot-check journal line (this boot) --------------------------------
JL="$(rsh bootcheck_journal 'journalctl -u ga-boot-check.service -b 0 --no-pager -q 2>/dev/null')"
if [ "$MODE" = unclean ]; then
    if printf '%s' "$JL" | grep -q "UNCLEAN SHUTDOWN DETECTED"; then ok "(b) ga-boot-check logged UNCLEAN SHUTDOWN DETECTED in this boot's journal"
    else bad "(b) ga-boot-check did NOT log UNCLEAN SHUTDOWN DETECTED in this boot's journal"; fi
else
    if printf '%s' "$JL" | grep -q "UNCLEAN SHUTDOWN DETECTED"; then bad "(b) clean reboot WRONGLY logged UNCLEAN SHUTDOWN DETECTED"
    elif printf '%s' "$JL" | grep -q "Clean boot"; then ok "(b) clean reboot: ga-boot-check reported a clean boot"
    else bad "(b) clean reboot: no ga-boot-check output at all in this boot's journal (check proves nothing)"; fi
fi

# --- c: verdict file for ga_manager ---------------------------------------------
V="$(rsh verdict 'test -f /mnt/data/supervisor/share/.ga_last_boot_unclean && echo present || echo absent' | tr -d '[:space:]')"
if [ "$MODE" = unclean ]; then
    [ "$V" = present ] && ok "(c) verdict file .ga_last_boot_unclean exists" || bad "(c) verdict file .ga_last_boot_unclean is MISSING"
else
    [ "$V" = absent ] && ok "(c) clean reboot: no verdict file" || bad "(c) clean reboot WRONGLY left a verdict file"
fi

# --- d: failure-trail dump --------------------------------------------------------
if [ "$HAS_DUMP" != yes ]; then
    skip "(d) image has no /usr/libexec/ga-journal-dump - dump not applicable"
else
    # newest bootcheck-unclean dump written since the drill started
    DUMP="$(rsh dump_list "for f in \$(ls -1t /mnt/data/journal-dump/dump-*-bootcheck-unclean.log.gz /mnt/data/journal-dump/dump-*-bootcheck-unclean.log 2>/dev/null); do
  m=\$(stat -c %Y \"\$f\" 2>/dev/null); [ \"\${m:-0}\" -ge $START_EPOCH ] && { echo \"\$f\"; break; }; done" | tr -d '\r' | head -1)"
    if [ "$MODE" = unclean ]; then
        if [ -z "$DUMP" ]; then bad "(d) no journal dump written by ga-boot-check since the reset"
        else
            case "$DUMP" in *.gz) rd="gzip -dc \"$DUMP\"" ;; *) rd="cat \"$DUMP\"" ;; esac
            n="$(rsh dump_read "$rd 2>/dev/null | head -c 100000 | wc -c" | tr -d '[:space:]')"
            if [ "${n:-0}" -gt 0 ] 2>/dev/null; then ok "(d) non-empty readable journal dump: ${DUMP##*/} (${n}+ bytes decoded)"
            else bad "(d) dump file exists but is empty/unreadable: ${DUMP##*/}"; fi
        fi
    else
        [ -z "$DUMP" ] && ok "(d) clean reboot: no bootcheck-unclean dump" || bad "(d) clean reboot WRONGLY wrote a bootcheck-unclean dump: ${DUMP##*/}"
    fi
fi

# --- e: telegraf (owner: telegraf WAL stream) ---------------------------------------
# skip_or_fail <msg>: SKIP normally, FAIL under --require-consent.
skip_or_fail() { if [ "$REQUIRE_CONSENT" = 1 ]; then bad "$1 [--require-consent: not allowed to skip]"; else skip "$1"; fi; }
METRICS_CONSENT="$(rsh consent_metrics 'test -f /mnt/data/.ga-consent-metrics && echo yes || echo no' | tr -d '[:space:]')"
LOGS_CONSENT="$(rsh consent_logs 'test -f /mnt/data/.ga-consent-error_logs && echo yes || echo no' | tr -d '[:space:]')"
waited=0 TG=""
if [ "$METRICS_CONSENT" != yes ]; then
    skip_or_fail "(e) NOT COVERED: no metrics consent (/mnt/data/.ga-consent-metrics absent) - telegraf is gated off by design"
else
while [ "$waited" -lt "$SETTLE_TIMEOUT" ]; do
    TG="$(rsh telegraf 'systemctl is-active telegraf.service 2>/dev/null' | tr -d '[:space:]')"
    [ "$TG" = active ] && break
    sleep "$POLL"; waited=$((waited + POLL))
done
if [ "$TG" = active ]; then ok "(e) [owner: telegraf WAL] telegraf.service is active after the reset"
else bad "(e) [owner: telegraf WAL] telegraf.service is '${TG:-unknown}' ${SETTLE_TIMEOUT}s after the reset (not a ga-boot-check/journal-dump/fluent-bit failure)"; fi
fi

# --- f: Loki ---------------------------------------------------------------------------
if [ -z "${LOKI_QUERY_URL:-}" ]; then
    skip_or_fail "(f) NOT COVERED: LOKI_QUERY_URL not set - Loki was not queried"
elif [ "$LOGS_CONSENT" != yes ]; then
    skip_or_fail "(f) NOT COVERED: no log consent (/mnt/data/.ga-consent-error_logs absent) - the tier-1 shipper is gated off by design"
elif [ -z "$LABEL" ]; then
    bad "(f) DEVICE_LABEL missing in $LABEL_FILE on a device with log consent - cannot select the device's Loki stream"
elif [ "${T1_ACTIVE:-}" != active ]; then
    skip_or_fail "(f) NOT COVERED: tier-1 shipper (fluent-bit.service) is '${T1_ACTIVE:-unknown}' on the device (telemetry consent?); tier-0 does not carry ga-boot-check lines"
else
    loki_count() {  # number of UNCLEAN lines for this device since the drill started
        local auth=() hdr=()
        [ -n "${LOKI_USER:-}" ] && auth=(-u "${LOKI_USER}:${LOKI_PASSWORD:-}")
        [ -n "${LOKI_TENANT:-}" ] && hdr=(-H "X-Scope-OrgID: ${LOKI_TENANT}")
        curl -fsS --max-time 20 "${auth[@]}" "${hdr[@]}" -G "${LOKI_QUERY_URL%/}/api/v1/query_range" \
            --data-urlencode "query={device_label=\"${LABEL}\"} |= \"UNCLEAN SHUTDOWN DETECTED\"" \
            --data-urlencode "start=${START_EPOCH}000000000" \
            --data-urlencode "end=$(( $(date +%s) + 60 ))000000000" \
            --data-urlencode "limit=100" 2>/dev/null \
          | python3 -c 'import sys,json
d=json.load(sys.stdin)
print(sum(len(s.get("values",[])) for s in d["data"]["result"]))' 2>/dev/null
    }
    if [ "$MODE" = unclean ]; then
        deadline=$(( $(date +%s) + LOKI_WAIT_MIN * 60 )) n=""
        while :; do
            n="$(loki_count)"
            [ -n "$n" ] && [ "$n" -ge 1 ] 2>/dev/null && break
            [ "$(date +%s)" -ge "$deadline" ] && break
            sleep 15
        done
        if [ -n "$n" ] && [ "$n" -ge 1 ] 2>/dev/null; then ok "(f) UNCLEAN SHUTDOWN DETECTED is queryable in Loki for this device ($n line(s))"
        elif [ -z "$n" ]; then bad "(f) Loki query FAILED (no parsable answer) - cannot say the line arrived"
        else bad "(f) UNCLEAN SHUTDOWN DETECTED did NOT reach Loki within ${LOKI_WAIT_MIN} min"; fi
    else
        sleep "$CLEAN_LOKI_WAIT"   # give a wrongly-shipped line time to arrive before asserting its absence
        n="$(loki_count)"
        if [ -z "$n" ]; then bad "(f) Loki query FAILED - cannot assert absence"
        elif [ "$n" -eq 0 ]; then ok "(f) clean reboot: no UNCLEAN line in Loki"
        else bad "(f) clean reboot WRONGLY produced $n UNCLEAN line(s) in Loki"; fi
    fi
fi

total=$((PASS + FAIL + SKIP))
echo ""
echo "--- Reset drill ($MODE): ${PASS} passed, ${FAIL} failed, ${SKIP} skipped (${total} total) ---"
printf '{"suite":"Reset drill %s","pass":%d,"fail":%d,"skip":%d}\n' "$MODE" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
