#!/bin/sh
# telegraf liveness + corrupt-WAL fault injection - runs ON the device.
#
# TGW-01..03  telegraf is really running (not just "unit active"): active, no
#             panic / write errors since its start, and it delivers metrics.
# TGW-10..16  INJECT the fault a hard reset causes: stop telegraf, corrupt the
#             newest disk-buffer segment, start telegraf, and assert that
#             ga-telegraf-buffer-check quarantines the buffer, logs it at
#             warning priority, and telegraf stays up. The injection is itself
#             asserted (telegraf must panic on the corrupted buffer BEFORE the
#             start), so the test cannot pass vacuously.
#
# Disruptive: stops/starts telegraf and drops the buffered, not yet delivered
# metrics. Bench devices only. Set TGW_NO_INJECT=1 to run the liveness half only.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Telegraf liveness + corrupt-WAL guard"

METRICS_MARKER="/mnt/data/.ga-consent-metrics"
TG_DIR="/mnt/data/telegraf"
BUF_DIR="$TG_DIR/buffer"
TG_CONF="/etc/telegraf/telegraf.conf"
[ -f "$TG_DIR/override.conf" ] && TG_CONF="$TG_DIR/override.conf"

# Telegraf is consent-gated; without consent it must not run (N/A, not a pass).
if [ ! -f "$METRICS_MARKER" ]; then
  warn_test "TGW-00" "metrics consent NOT given - telegraf suite N/A (expected)" "true"
  suite_end
  return 0 2>/dev/null || exit 0
fi

# journal of the CURRENT run of the unit (since its last start)
tg_since() { systemctl show -p ActiveEnterTimestamp --value telegraf 2>/dev/null; }
tg_journal() { journalctl -u telegraf --no-pager -q --since "$(tg_since)" 2>/dev/null; }

# --- liveness --------------------------------------------------------------
run_test "TGW-01" "telegraf.service is active" "systemctl is-active --quiet telegraf"

run_test "TGW-02" "no panic and no output write error in the current run" \
  "! tg_journal | grep -E 'panic:|E! .*Error writing to outputs'"

# "Wrote batch" is logged at debug level only; the shipped config runs at info,
# so it is accepted when present, otherwise delivery is shown by the absence of
# write errors for >= 2 flush intervals while the unit has been up that long.
deliver_ok() {
  tg_journal | grep -q 'Wrote batch' && return 0
  up=$(( $(date +%s) - $(date -d "$(tg_since)" +%s 2>/dev/null || echo "$(date +%s)") ))
  [ "$up" -ge 30 ] && ! tg_journal | grep -qE 'E! .*(Error writing|did not complete within its flush interval)'
}
run_test "TGW-03" "telegraf delivers (Wrote batch, or up >= 30 s with no write errors)" "deliver_ok"

if [ "${TGW_NO_INJECT:-0}" = "1" ]; then
  warn_test "TGW-10" "fault injection skipped (TGW_NO_INJECT=1)" "true"
  suite_end
  return 0 2>/dev/null || exit 0
fi

# --- fault injection ---------------------------------------------------------
run_test "TGW-09" "guard is installed and executable" "test -x /usr/libexec/ga-telegraf-buffer-check"
run_test "TGW-09b" "telegraf.service runs the guard before start" \
  "systemctl cat telegraf | grep -q '^ExecStartPre=.*ga-telegraf-buffer-check'"

BEFORE_Q=$(ls -d "$TG_DIR"/buffer.corrupt-* 2>/dev/null | sort)
# The WAL dir the RUNNING telegraf writes to: the directory of the segment file
# it holds open (its WAL directory name is a hash of the output config; stale
# dirs from other configs can sit beside it). Resolved BEFORE the stop.
MPID=$(systemctl show -p MainPID --value telegraf 2>/dev/null)
SEG=""
if [ -n "$MPID" ] && [ "$MPID" != 0 ]; then
  SEG=$(ls -l /proc/"$MPID"/fd 2>/dev/null | sed -n "s|.* -> \\($BUF_DIR/.*\\)\$|\\1|p" | sort | tail -1)
fi
REAL_DIR=""
[ -n "$SEG" ] && REAL_DIR=$(dirname "$SEG")
run_test "TGW-09c" "resolved the WAL segment the running telegraf has open" "[ -n \"$SEG\" ] && [ -f \"$SEG\" ]"
systemctl stop telegraf
if [ -z "$SEG" ] || [ ! -f "$SEG" ]; then
  # Fail closed: corrupting some other dir would prove nothing.
  systemctl start telegraf
  suite_end
  return 0 2>/dev/null || exit 0
fi
SZ=$(wc -c < "$SEG")
if [ "$SZ" -ge 1000 ]; then
  truncate -s $((SZ - 700)) "$SEG"          # tear the last record mid-way
else
  head -c 64 /dev/urandom >> "$SEG"         # garbage tail
fi

# The injection must have produced the real fault, else nothing below counts.
PANIC=$(timeout 60 /usr/bin/telegraf --config "$TG_CONF" --test --input-filter mem 2>&1 | grep -E 'panic: failed to open wal file|log corrupt' | head -1)
run_test "TGW-10" "injection worked: telegraf panics on the corrupted buffer" "[ -n \"$PANIC\" ]"

START_TS=$(date '+%Y-%m-%d %H:%M:%S')
systemctl start telegraf
sleep 60

run_test "TGW-11" "telegraf is active 60 s after the start with a corrupt buffer" \
  "systemctl is-active --quiet telegraf"

AFTER_Q=$(ls -d "$TG_DIR"/buffer.corrupt-* 2>/dev/null | sort)
NEW_Q=$(printf '%s\n' "$AFTER_Q" | while IFS= read -r q; do
  [ -n "$q" ] && ! printf '%s\n' "$BEFORE_Q" | grep -qxF "$q" && echo "$q"; done | tail -1)
run_test "TGW-12" "a new buffer.corrupt-* quarantine exists" "[ -n \"$NEW_Q\" ] && [ -d \"$NEW_Q\" ]"
run_test "TGW-13" "the corrupted WAL dir (the one telegraf wrote to) is in the quarantine" \
  "[ -n \"$NEW_Q\" ] && [ -d \"$NEW_Q/$(basename "$REAL_DIR")\" ]"
run_test "TGW-14" "a fresh buffer dir exists" "[ -d $BUF_DIR ]"
run_test "TGW-15" "warning line (priority 4) in the journal" \
  "journalctl -u telegraf -p warning --since '$START_TS' --no-pager -q | grep -q 'ga-telegraf-buffer-check.*CORRUPT'"
run_test "TGW-16" "no quarantines beyond the bound of 2" \
  "[ \$(ls -d $TG_DIR/buffer.corrupt-* | wc -l) -le 2 ]"

# Clean up what this test created (keep the device as found).
[ -n "$NEW_Q" ] && rm -rf "$NEW_Q"

suite_end
