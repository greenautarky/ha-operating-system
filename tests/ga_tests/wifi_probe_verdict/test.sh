#!/bin/sh
# HW-02b's log reading, driven against fixtures — host-side, no device.
#
# WHY THIS EXISTS: HW-02 was one check over a volatile source, and on
# 2026-09-23 it went red on a healthy K31 whose driver was loaded and whose logs
# had simply aged past boot. Splitting it is only half the work; the reading is
# now a function, and a function with no fixtures rots silently. Two sets, per
# working-method rule 51:
#
#   MUST FLAG      a log carrying an eFuse failure → `efuse`
#   MUST NOT FLAG  a healthy log → `clean`; a log that cannot answer → `uncovered`
#
# The must-not-flag set is not padding: every false red this check ever produced
# goes in it, so it cannot come back. WPV-05 IS that red — the exact K31 state,
# a non-empty but rotated journal in front of a dmesg that still has the probe
# line. The pre-fix form chose the journal because it was non-empty and answered
# "uncovered"; the fix concatenates, so the evidence is found.
#
# It sources the LIVE hardware/wifi_probe.sh. It must never re-declare the
# patterns: a self-test over its own copy stays green while the real check rots.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "wifi probe verdict (HW-02b fixtures)"

LIVE="$SCRIPT_DIR/../hardware/wifi_probe.sh"

# If the extraction stops finding the definition, FAIL — never skip. A green
# self-test over a file it could not read is the failure class this guards.
if [ ! -f "$LIVE" ]; then
  run_test "WPV-01" "the live definition is where HW-02b reads it ($LIVE)" "false"
  suite_end
  exit 1
fi
run_test "WPV-01" "the live definition defines both functions" \
  "grep -q '^wifi_probe_verdict()' '$LIVE' && grep -q '^wifi_kernel_log()' '$LIVE'"

# shellcheck source=/dev/null
. "$LIVE"

verdict() { printf '%s' "$1" | wifi_probe_verdict; }

# The real K31 dmesg line, copied from the device on 2026-09-23.
K31_DMESG='[    6.311479] rtw_8723ds mmc1:0001:1: Firmware version 48.0.0, H2C version 0'
# The shape of a journal that is non-empty but no longer reaches boot: K31 had
# 197 such lines whose oldest entry was 59 minutes old at 21 h uptime.
ROTATED='Sep 23 11:41:35 KiBu kernel: mmc1: new ultra high speed SDR104 SDIO card
Sep 23 11:42:01 KiBu kernel: wlan0: authenticate with 02:00:00:00:00:01
Sep 23 12:03:17 KiBu kernel: wlan0: associated'
EFUSE='[    5.902001] rtw_8723ds mmc1:0001:1: failed to dump efuse logical map'

run_test "WPV-02" "MUST FLAG: an eFuse dump failure is reported as efuse" \
  "[ \"\$(verdict \"\$EFUSE\")\" = efuse ]"

run_test "WPV-03" "MUST NOT FLAG: the real K31 probe line is clean" \
  "[ \"\$(verdict \"\$K31_DMESG\")\" = clean ]"

run_test "WPV-04" "a rotated journal alone cannot answer → uncovered" \
  "[ \"\$(verdict \"\$ROTATED\")\" = uncovered ]"

# THE red this whole change exists for.
run_test "WPV-05" "MUST NOT FLAG: rotated journal in front of a dmesg that HAS the probe → clean" \
  "[ \"\$(verdict \"\$ROTATED
\$K31_DMESG\")\" = clean ]"

run_test "WPV-06" "an empty log → uncovered, not clean" \
  "[ \"\$(verdict '')\" = uncovered ]"

run_test "WPV-07" "MUST NOT FLAG: the module-name spelling counts as coverage too" \
  "[ \"\$(verdict 'rtw88_8723ds: module loaded')\" = clean ]"

# The concatenation must work in both directions: an eFuse failure in the
# journal half must not be lost behind a dmesg that has rotated.
run_test "WPV-08" "MUST FLAG: an eFuse failure in the journal half survives the concatenation" \
  "[ \"\$(verdict \"\$EFUSE
Sep 23 12:03:17 KiBu kernel: wlan0: associated\")\" = efuse ]"


# WPV-09/10 drive the LOG SELECTION, which is where the defect actually lived:
# `wifi_kernel_log` with a stub journalctl and a stub dmesg on PATH. WPV-09 is
# the K31 state of 2026-09-23 end to end — a journal that answers with 197
# useless lines, a dmesg that still has the probe line. The pre-fix selection
# (`[ -n "$K" ] || K=$(dmesg)`) never reached the second one.
STUB="$(mktemp -d 2>/dev/null || echo /tmp/wpv_$$)"
mkdir -p "$STUB/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$WPV_JOURNAL"\n' > "$STUB/bin/journalctl"
printf '#!/bin/sh\nprintf "%%s\\n" "$WPV_DMESG"\n'   > "$STUB/bin/dmesg"
chmod +x "$STUB/bin/journalctl" "$STUB/bin/dmesg"

selection() {   # selection <journal> <dmesg>
  WPV_JOURNAL="$1" WPV_DMESG="$2" PATH="$STUB/bin:$PATH" \
    sh -c ". '$LIVE'; wifi_kernel_log | wifi_probe_verdict"
}

run_test "WPV-09" "MUST NOT FLAG: rotated journal + dmesg with the probe → clean (the K31 state, through the live selection)" \
  "[ \"\$(selection \"\$ROTATED\" \"\$K31_DMESG\")\" = clean ]"

run_test "WPV-10" "a device whose journal DOES reach boot is answered from the journal" \
  "[ \"\$(selection \"\$K31_DMESG\" '')\" = clean ]"

run_test "WPV-11" "MUST FLAG: an eFuse failure only dmesg still has is not lost" \
  "[ \"\$(selection \"\$ROTATED\" \"\$EFUSE\")\" = efuse ]"

rm -rf "$STUB"

suite_end
