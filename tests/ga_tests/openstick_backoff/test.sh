#!/bin/sh
# ga-openstick-autoconnect must not keep re-joining a dongle SSID that proved to
# have no internet (Odoo #2112, K31 bench 2026-11-17).
#
# THE FAILURE: the dongle's Wi-Fi is up but has no WAN (no SIM, or a SIM without
# a data service). The script joins it, NM says `limited`, it deletes the
# profile and sets a 300 s cooldown. The device is back on the install Wi-Fi in
# ~30 s - and does it again 10 minutes later, for as long as the stick
# broadcasts: a ~30 s outage every 10 min.
#
# The subject is the REAL script. Only the seams are stubbed: nmcli, sleep (it
# advances a simulated clock, so a tick costs the ~40 s it costs on the device),
# date and logger. The same suite runs red against the pre-fix script.
set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$ROOT/buildroot-ihost/rootfs-overlay/usr/sbin/ga-openstick-autoconnect"
W="$(mktemp -d -t openstick-backoff-XXXXXX)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"

pass=0; fail=0
PASS() { echo "  PASS  $1"; pass=$((pass+1)); }
FAIL() { echo "  FAIL  $1 ($2)"; fail=$((fail+1)); }

# ── stubs ───────────────────────────────────────────────────────────────────
cat > "$W/bin/sleep" <<'STUB'
#!/bin/sh
echo $(( $(cat "$CLOCK") + $1 )) > "$CLOCK"
STUB
cat > "$W/bin/date" <<'STUB'
#!/bin/sh
if [ "$*" = "+%s" ]; then cat "$CLOCK"; else exec /bin/date "$@"; fi
STUB
cat > "$W/bin/logger" <<'STUB'
#!/bin/sh
echo "$*" >> "$LOGGER_OUT"
STUB
# a NetworkManager with one profile (openstick-auto) and a world the test sets:
#   OTHER_VERDICT  what NM says while the stick is NOT the active rung
#   STICK_VERDICT  what NM says while the stick IS active
cat > "$W/bin/nmcli" <<'STUB'
#!/bin/sh
case "$*" in
  "dev wifi rescan") : ;;
  "-t -f SSID,SIGNAL dev wifi list") cat "$SCAN" ;;
  "-t -f NAME connection show --active") [ -f "$ST/active" ] && echo openstick-auto ;;
  "connection delete openstick-auto") [ -f "$ST/exists" ] && echo DELETE >> "$ST/events"; rm -f "$ST/exists" "$ST/active" ;;
  "connection add type wifi"*)
      echo ADD >> "$ST/events"; touch "$ST/exists"
      for _a in "$@"; do [ "${_p:-}" = ssid ] && echo "$_a" > "$ST/ssid"; _p="$_a"; done ;;
  "connection up openstick-auto") [ -f "$ST/exists" ] && touch "$ST/active" ;;
  "-g 802-11-wireless.ssid connection show openstick-auto") cat "$ST/ssid" 2>/dev/null ;;
  "-t -f CONNECTIVITY general status"|"networking connectivity check")
      if [ -f "$ST/active" ]; then echo "$STICK_VERDICT"; else echo "$OTHER_VERDICT"; fi ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$W/bin/"*

export CLOCK="$W/clock" ST="$W/st" SCAN="$W/scan" LOGGER_OUT="$W/logger.out"
export GA_OPENSTICK_SLEEP="$W/bin/sleep" GA_OPENSTICK_KEY_FILE="$W/key"
export GA_OPENSTICK_COOLDOWN_FILE="$W/cooldown" GA_OPENSTICK_BACKOFF_FILE="$W/backoff"
export GA_LADDER_PARK_DIR="$W/parked"
printf 'deadbeef' > "$W/key"

reset() {
    rm -rf "$ST" "$W/cooldown" "$W/backoff" "$W/parked" "$W/tick.out"; mkdir -p "$ST" "$W/parked"
    : > "$ST/events"; : > "$LOGGER_OUT"
    printf 'GA-5320:70\nGreenAutarky-Install:80\n' > "$SCAN"
    OTHER_VERDICT=full; STICK_VERDICT=limited; export OTHER_VERDICT STICK_VERDICT
}
tick() {   # tick <epoch>
    echo "$1" > "$CLOCK"
    PATH="$W/bin:$PATH" sh "$SCRIPT" >> "$W/tick.out" 2>&1
}
count() { grep -c "^$1\$" "$ST/events"; }
until_of() { awk -F'\t' '$1=="GA-5320"{print $3}' "$W/backoff" 2>/dev/null; }
T0=1000000

echo ""
echo "=== ga-openstick-autoconnect back-off ==="

echo "--- K31 replay: dongle Wi-Fi up, NO WAN, install Wi-Fi full (the 2026-11-17 bench case) ---"
reset
t=$T0; while [ $t -lt $((T0 + 1800)) ]; do tick $t; t=$((t + 300)); done
n=$(count ADD)
[ "$n" = "1" ] && PASS "30 min of 5-min timer ticks: exactly 1 join (was 3 - a 30 s outage every 10 min)" \
    || FAIL "no flapping on a dongle without WAN" "joins=$n in 30 min"
[ "$(count DELETE)" = "1" ] && PASS "the no-data profile was deleted once, so the device is on the install Wi-Fi" || FAIL "profile deleted once" "deletes=$(count DELETE)"
t=$((T0 + 1800)); while [ $t -lt $((T0 + 2400)) ]; do tick $t; t=$((t + 300)); done
[ "$(count ADD)" = "1" ] && PASS "still barred 40 min into the run (bar >= 30 min)" || FAIL "bar holds >= 30 min" "joins=$(count ADD)"
grep -q 'GA-5320' "$W/backoff" 2>/dev/null && PASS "the bar is persisted per SSID" || FAIL "back-off persisted" "no entry in the back-off file"
grep -qE 'daemon\.(warning|err)' "$LOGGER_OUT" && grep -qi 'barred' "$LOGGER_OUT" \
    && PASS "barring is logged loudly (daemon.warning), not at INFO" || FAIL "loud bar log" "$(cat "$LOGGER_OUT")"

echo "--- SIM without a data service: verdict none / portal while associated -> same expectation ---"
reset; STICK_VERDICT=none; export STICK_VERDICT
t=$T0; while [ $t -lt $((T0 + 1800)) ]; do tick $t; t=$((t + 300)); done
[ "$(count ADD)" = "1" ] && PASS "verdict 'none': 1 join in 30 min" || FAIL "verdict none, no flapping" "joins=$(count ADD)"
reset; STICK_VERDICT=portal; export STICK_VERDICT
t=$T0; while [ $t -lt $((T0 + 1800)) ]; do tick $t; t=$((t + 300)); done
[ "$(count ADD)" = "1" ] && PASS "verdict 'portal': 1 join in 30 min" || FAIL "verdict portal, no flapping" "joins=$(count ADD)"

echo "--- the dongle must be tried again eventually (it may be the only uplink later) ---"
reset
tick $T0
u=$(until_of)
if [ -n "$u" ]; then tick $((u + 1)); else tick $((T0 + 7200)); fi
[ "$(count ADD)" = "2" ] && PASS "after the bar expires the SSID is joined again" || FAIL "retry after bar" "joins=$(count ADD)"

echo "--- the bar grows and is capped ---"
reset
prev=0; ok=1; seq=""
i=0; while [ $i -lt 6 ]; do
    i=$((i+1))
    t=$((prev + 1)); [ "$t" -gt "$T0" ] || t=$T0
    tick $t
    fin=$(cat "$CLOCK")
    u=$(until_of); [ -n "$u" ] || { ok=0; break; }
    seq="$seq $((u - fin))"; prev=$u
done
echo "        bar lengths (s):$seq"
set -- $seq
if [ "$ok" = 1 ] && [ "$#" -eq 6 ] && [ "$1" -ge 1800 ] && [ "$2" -gt "$1" ] && [ "$3" -gt "$2" ] && [ "$4" -ge "$3" ] && [ "$4" -le 21600 ] && [ "$5" -eq "$4" ] && [ "$6" -eq "$4" ]; then
    PASS "bar grows (>= 30 min, then longer), is capped at 6 h, and stays capped"
else FAIL "growing, capped back-off" "lengths:$seq"; fi

echo "--- the bar survives a reboot (persisted in /mnt/data, not /run) ---"
reset
tick $T0
rm -rf "$W/parked" "$ST/active"      # a reboot wipes /run; the back-off file stays
tick $((T0 + 600))
[ "$(count ADD)" = "1" ] && PASS "after a reboot the barred SSID is still not re-joined" || FAIL "bar survives reboot" "joins=$(count ADD)"

echo "--- MUST NOT FLAG: dongle is the ONLY uplink (nothing else full) -> stay, never delete ---"
reset; OTHER_VERDICT=none; STICK_VERDICT=limited; export OTHER_VERDICT STICK_VERDICT
t=$T0; while [ $t -lt $((T0 + 3600)) ]; do tick $t; t=$((t + 300)); done
[ "$(count DELETE)" = "0" ] && PASS "the dongle profile is NOT deleted while no other rung is full" || FAIL "dongle-only keeps its profile" "deletes=$(count DELETE)"
{ [ "$(count ADD)" = "1" ] && [ -f "$ST/exists" ] && [ -f "$ST/active" ]; } && PASS "and the device stays on it (1 join, still active)" || FAIL "dongle-only stays" "joins=$(count ADD)"
[ ! -s "$W/backoff" ] && PASS "no back-off recorded when no better rung exists" || FAIL "no bar when alone" "$(cat "$W/backoff")"

echo "--- MUST NOT FLAG: ethernet dies while the dongle is barred -> bar ignored, dongle joined and kept ---"
reset
tick $T0                                  # fails while ethernet is full: barred
OTHER_VERDICT=none; export OTHER_VERDICT  # ethernet dies; the dongle is all there is
tick $((T0 + 600))
[ "$(count ADD)" = "2" ] && PASS "nothing else full: the bar is lifted and the dongle is joined at once" || FAIL "bar lifted when nothing else is full" "joins=$(count ADD)"
[ "$(count DELETE)" = "1" ] && PASS "and that join is not deleted (device would be offline)" || FAIL "no delete when alone" "deletes=$(count DELETE)"
grep -qi 'lifted' "$LOGGER_OUT" && PASS "the lifted bar is logged loudly" || FAIL "loud unbar" "$(cat "$LOGGER_OUT")"

echo "--- MUST NOT FLAG: a 'full' dongle is kept, and no bar is recorded ---"
reset; STICK_VERDICT=full; export STICK_VERDICT
t=$T0; while [ $t -lt $((T0 + 1800)) ]; do tick $t; t=$((t + 300)); done
{ [ "$(count ADD)" = "1" ] && [ "$(count DELETE)" = "0" ] && [ -f "$ST/active" ]; } && PASS "full dongle: joined once, kept, active" || FAIL "full dongle kept" "adds=$(count ADD) deletes=$(count DELETE)"
[ ! -s "$W/backoff" ] && PASS "no bar for a dongle that works" || FAIL "no bar on full" "$(cat "$W/backoff")"

echo "--- the bar resets on a later 'full' verdict ---"
reset
tick $T0                                  # no WAN: barred
u=$(until_of)
STICK_VERDICT=full; export STICK_VERDICT  # the SIM got data
tick $((u + 1))
{ [ "$(count ADD)" = "2" ] && [ -f "$ST/active" ]; } && PASS "after the bar the dongle is retried and now verifies full" || FAIL "retry verifies full" "adds=$(count ADD)"
[ ! -s "$W/backoff" ] && PASS "full verdict clears the back-off entry" || FAIL "reset on full" "$(cat "$W/backoff")"
grep -qi 'unbarred\|reset' "$LOGGER_OUT" && PASS "the reset is logged" || FAIL "loud reset" "$(cat "$LOGGER_OUT")"

echo "--- an active dongle that is full clears a stale bar (cached verdict, no traffic) ---"
reset
printf 'GA-5320\t3\t%s\n' $((T0 + 99999)) > "$W/backoff"
printf 'GA-5320\n' > "$ST/ssid"; touch "$ST/exists" "$ST/active"; STICK_VERDICT=full; export STICK_VERDICT
tick $T0
[ ! -s "$W/backoff" ] && PASS "stale bar dropped once the active dongle reports full" || FAIL "reset by the active-rung check" "$(cat "$W/backoff")"

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
