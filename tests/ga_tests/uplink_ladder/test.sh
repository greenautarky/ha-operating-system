#!/bin/sh
# The uplink ladder's decisions, driven against a stub NetworkManager.
#
# The subject under test is the REAL script. Only `nmcli` and `ip` are stubbed,
# because they are the seam to the network — everything the script decides runs
# for real, including the two rules it must never break:
#
#   * never park the last rung (parking it would cause the outage)
#   * a healthy device costs no probe traffic (the "fast only when suspicious"
#     rule — on a metered SIM this is the difference between free and billed)
#
# Half of the checks below are must-NOT-flag for that reason: a ladder that
# parks eagerly, or probes every two minutes on a healthy device, would be
# switched off by the first person who reads a data bill.
set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LADDER="$ROOT/buildroot-ihost/rootfs-overlay/usr/sbin/ga-uplink-ladder"
WORK="$(mktemp -d -t uplink-ladder-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
PASS() { echo "  PASS  $1"; pass=$((pass+1)); }
FAIL() { echo "  FAIL  $1 ($2)"; fail=$((fail+1)); }

# ── the stub: a NetworkManager whose answers the test controls ──────────────
cat > "$WORK/nmcli" <<'STUB'
#!/bin/sh
echo "$*" >> "$NM_LOG"
case "$*" in
  *"-f CONNECTIVITY general status")   cat "$NM_CACHED" ;;
  "networking connectivity check")     cat "$NM_FORCED" ;;
  *"-f NAME,DEVICE connection show --active") cat "$NM_ACTIVE" ;;
  *"-f NAME,AUTOCONNECT connection show")     cat "$NM_PROFILES" ;;
  *) : ;;
esac
STUB
cat > "$WORK/ip" <<'STUB'
#!/bin/sh
cat "$IP_ROUTE"
STUB
chmod +x "$WORK/nmcli" "$WORK/ip"

run() {   # run <cached> <forced> <profiles-file> [now]
    : > "$WORK/nm.log"
    printf '%s\n' "$1" > "$WORK/cached"
    printf '%s\n' "$2" > "$WORK/forced"
    NM_LOG="$WORK/nm.log" NM_CACHED="$WORK/cached" NM_FORCED="$WORK/forced" \
    NM_ACTIVE="$WORK/active" NM_PROFILES="$3" IP_ROUTE="$WORK/route" \
    GA_NMCLI="$WORK/nmcli" GA_IP="$WORK/ip" \
    GA_LADDER_STATE="$WORK/state" GA_LADDER_BOOT_MARK="$WORK/booted" \
    GA_LADDER_PARK_DIR="$WORK/parked" GA_LADDER_STATUS="$WORK/status.json" \
    GA_LADDER_NOW="${4:-1000000}" GA_LADDER_COOLDOWN_S=900 \
      sh "$LADDER" >/dev/null 2>&1
}
parked_count() { ls "$WORK/parked" 2>/dev/null | wc -l | tr -d ' '; }
probed() { grep -c "networking connectivity check" "$WORK/nm.log"; }

# a device on the customer WiFi, with the LTE stick as a spare rung
printf 'default dev wlan0 scope link\n' > "$WORK/route"  # no address: the script only reads the interface, and this repo is public
printf 'home-wifi:wlan0\n' > "$WORK/active"
printf 'home-wifi:yes\nopenstick-auto:yes\nGreenAutarky-Install:yes\n' > "$WORK/two-rungs"
printf 'home-wifi:yes\n' > "$WORK/one-rung"

echo ""
echo "=== uplink ladder ==="

# ── healthy: no probe, no park, strike counter at zero ──────────────────────
echo "--- a healthy device is left alone ---"
rm -rf "$WORK/state" "$WORK/parked" "$WORK/booted"
run full full "$WORK/two-rungs"
[ "$(probed)" = "0" ] && PASS "cached 'full' costs no probe (metered SIM stays unbilled)" \
    || FAIL "healthy device does not probe" "forced a connectivity check"
[ "$(parked_count)" = "0" ] && PASS "nothing parked while the uplink works" || FAIL "healthy device untouched" "something was parked"
grep -q '"verdict":"full"' "$WORK/status.json" && PASS "status names the rung and the verdict" || FAIL "status written" "$(cat "$WORK/status.json" 2>/dev/null)"

# ── suspicion: one probe, still no park before the threshold ────────────────
echo "--- suspicion probes once, and waits ---"
rm -rf "$WORK/state" "$WORK/parked" "$WORK/booted"
run limited limited "$WORK/two-rungs"
[ "$(probed)" = "1" ] && PASS "a suspect tick forces exactly one probe" || FAIL "suspicion probes once" "probes=$(probed)"
[ "$(parked_count)" = "0" ] && PASS "one bad reading is not enough to switch" || FAIL "no park on strike 1" "parked too early"
run limited limited "$WORK/two-rungs"
[ "$(parked_count)" = "0" ] && PASS "two bad readings are still not enough" || FAIL "no park on strike 2" "parked too early"

# ── third strike: park, and only then ───────────────────────────────────────
echo "--- the third strike switches ---"
run limited limited "$WORK/two-rungs"
[ "$(parked_count)" = "1" ] && PASS "three confirmed strikes park the dead rung" || FAIL "park on strike 3" "parked=$(parked_count)"
grep -q "connection down home-wifi" "$WORK/nm.log" \
    && PASS "parking takes the profile DOWN (one radio, one association)" \
    || FAIL "park downs the connection" "$(tr '\n' ';' < "$WORK/nm.log")"
grep -q "connection modify home-wifi connection.autoconnect no" "$WORK/nm.log" \
    && PASS "parking also stops it from coming straight back" || FAIL "park disables autoconnect" "missing"

# ── a recovered uplink clears the strikes ───────────────────────────────────
echo "--- recovery ---"
rm -rf "$WORK/state" "$WORK/parked" "$WORK/booted"
run limited limited "$WORK/two-rungs"; run limited limited "$WORK/two-rungs"
run full full "$WORK/two-rungs"
[ "$(cat "$WORK/state")" = "0" ] && PASS "a good reading resets the strike count" || FAIL "recovery resets strikes" "state=$(cat "$WORK/state")"

# ── the rule that matters most: never park the last rung ────────────────────
echo "--- the last rung is never parked ---"
rm -rf "$WORK/state" "$WORK/parked" "$WORK/booted"
run none none "$WORK/one-rung"; run none none "$WORK/one-rung"; run none none "$WORK/one-rung"
[ "$(parked_count)" = "0" ] \
    && PASS "a device with nowhere to fall keeps what it has" \
    || FAIL "last rung is never parked" "the ladder took the device off the network"

# ── cooldown: unpark only when it has expired ───────────────────────────────
echo "--- cooldown ---"
rm -rf "$WORK/state" "$WORK/parked" "$WORK/booted"
run limited limited "$WORK/two-rungs"; run limited limited "$WORK/two-rungs"; run limited limited "$WORK/two-rungs"
run full full "$WORK/two-rungs" 1000300     # 300 s later, cooldown is 900 s
[ "$(parked_count)" = "1" ] && PASS "a parked rung stays parked until its cooldown ends" || FAIL "cooldown holds" "released too early"
run full full "$WORK/two-rungs" 1001000     # past the cooldown
[ "$(parked_count)" = "0" ] && PASS "after the cooldown it may compete again" || FAIL "cooldown releases" "still parked"
grep -q "connection modify home-wifi connection.autoconnect yes" "$WORK/nm.log" \
    && PASS "unparking restores autoconnect" || FAIL "unpark restores autoconnect" "missing"

# ── a reboot is a fresh start ───────────────────────────────────────────────
echo "--- reboot clears every park ---"
rm -rf "$WORK/state" "$WORK/parked" "$WORK/booted"
run limited limited "$WORK/two-rungs"; run limited limited "$WORK/two-rungs"; run limited limited "$WORK/two-rungs"
[ "$(parked_count)" = "1" ] || FAIL "precondition: something is parked" "nothing parked"
rm -f "$WORK/booted"                        # what a reboot looks like to the script
run full full "$WORK/two-rungs"
[ "$(parked_count)" = "0" ] \
    && PASS "after a reboot every rung gets to try again" \
    || FAIL "reboot unparks" "a decision from before the reboot still disables a rung"

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
