#!/bin/sh
# lte_rat — dsgw210-lte-rat.sh READS the BG96 RAT configuration and never writes it (Odoo #2187 A).
# Drives the LIVE script against a fake BG96 on a pty (fake_bg96.py logs every command).
#   LRT-01  all four QCFG values + firmware read, status JSON carries them and "written":false
#   LRT-02  no QCFG SET form reaches the modem (query only)            [the guard]
#   LRT-03  guard red proof: the pre-#2187 behaviour (must-fail fixture) IS flagged by LRT-02's check
#   LRT-04  a silent modem: the script still exits 0 within its bound and claims no values
#   LRT-05  the unit still orders before ModemManager and the script is query-only by text
set -u
D="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$D/../../.." && pwd)"
LIVE="$ROOT/buildroot-dsgw210/board/dusun/dsgw210/rootfs-overlay/usr/bin/dsgw210-lte-rat.sh"
UNIT="$ROOT/buildroot-dsgw210/board/dusun/dsgw210/rootfs-overlay/usr/lib/systemd/system/dsgw210-lte-rat.service"
W="$(mktemp -d)"; trap 'kill $FP 2>/dev/null; rm -rf "$W"' EXIT
pass=0; fail=0
PASS() { echo "  PASS  $1"; pass=$((pass+1)); }
FAIL() { echo "  FAIL  $1${2:+ ($2)}"; fail=$((fail+1)); }
echo ""; echo "=== lte_rat: read the BG96 RAT config, never write it ==="
for f in "$LIVE" "$UNIT" "$D/fake_bg96.py" "$D/must-fail/writes-qcfg.sh"; do [ -r "$f" ] || { echo "FATAL: missing $f"; exit 1; }; done
command -v python3 >/dev/null || { echo "FATAL: python3 needed for the fake modem"; exit 1; }

run() {  # <script> <name> [silent] -> commands in $W/<name>.cmds, status in $W/<name>.json, rc in $W/<name>.rc
  : > "$W/$2.cmds"; rm -f "$W/$2.path"
  python3 "$D/fake_bg96.py" "$W/$2.cmds" "$W/$2.path" ${3:+silent} & FP=$!
  i=0; while [ ! -s "$W/$2.path" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  t0=$(date +%s)
  GA_LTE_AT="$(cat "$W/$2.path")" GA_LTE_RAT_STATUS="$W/$2.json" GA_LTE_RAT_TMP="$W/$2.out" GA_LTE_RAT_REPLY_S=1 \
    timeout 120 sh "$1" > "$W/$2.log" 2>&1; echo $? > "$W/$2.rc"
  echo $(( $(date +%s) - t0 )) > "$W/$2.secs"
  kill $FP 2>/dev/null; wait $FP 2>/dev/null
}
# the guard: any AT+QCFG="name",<something> is a SET form
writes() { grep -E '^AT\+QCFG="[a-z]+",' "$1" >/dev/null; }

run "$LIVE" live
n=$(grep -c '^AT+QCFG="' "$W/live.cmds")
if [ "$(cat "$W/live.rc")" = 0 ] && [ "$n" -eq 4 ] && grep -q '"nwscanmode":"0"' "$W/live.json" 2>/dev/null \
   && grep -q '"band":"0xf,0x400a0e189f,0xa0e189f"' "$W/live.json" && grep -q '"firmware":"BG96MAR02A07M1G_01.200.01.200"' "$W/live.json" \
   && grep -q '"written":false' "$W/live.json"; then PASS "LRT-01 four QCFG values + firmware read into the status JSON, written=false"
else FAIL "LRT-01 read" "rc=$(cat "$W/live.rc") queries=$n json=$(cat "$W/live.json" 2>/dev/null) log=$(tr '\n' ' ' < "$W/live.log")"; fi
if [ "$n" -ge 4 ] && ! writes "$W/live.cmds"; then PASS "LRT-02 no QCFG SET form reached the modem ($n queries inspected)"
else FAIL "LRT-02 query-only" "$(tr '\n' ' ' < "$W/live.cmds")"; fi

run "$D/must-fail/writes-qcfg.sh" redproof
if writes "$W/redproof.cmds"; then PASS "LRT-03 red proof: the pre-#2187 write behaviour is flagged ($(grep -c '^AT+QCFG="[a-z]*",' "$W/redproof.cmds") set forms)"
else FAIL "LRT-03 red proof" "the guard did not flag the fixture: $(tr '\n' ' ' < "$W/redproof.cmds")"; fi

run "$LIVE" silent silent
s=$(cat "$W/silent.secs")
if [ "$(cat "$W/silent.rc")" = 0 ] && [ "$s" -le 110 ] && [ ! -s "$W/silent.json" ] && grep -q "not answering AT" "$W/silent.log"; then
  PASS "LRT-04 silent modem: exit 0 after ${s}s, no values claimed"
else FAIL "LRT-04 silent modem" "rc=$(cat "$W/silent.rc") secs=$s json=$(cat "$W/silent.json" 2>/dev/null)"; fi

if grep -q '^Before=ModemManager.service' "$UNIT" && ! grep -qE 'QCFG="[a-z]+",' "$LIVE"; then PASS "LRT-05 unit before ModemManager; script text has no QCFG set form"
else FAIL "LRT-05 unit/script text"; fi

echo ""; echo "lte_rat: $pass passed, $fail failed"
echo "{\"suite\":\"lte_rat\",\"pass\":$pass,\"fail\":$fail,\"skip\":0}"
[ "$fail" -eq 0 ] && [ "$pass" -eq 5 ]
