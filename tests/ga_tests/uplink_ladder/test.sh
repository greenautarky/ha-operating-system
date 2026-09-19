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
  *"-f NAME,TYPE,AUTOCONNECT connection show") cat "$NM_PROFILES" ;;
  *"-f connection.interface-name connection show "*) echo "connection.interface-name:${NM_IFACE:-eth0}" ;;
  *"-f 802-11-wireless.ssid connection show "*)
      # the ssid of the profile named last on the command line
      for _a in $*; do :; done; echo "802-11-wireless.ssid:${_a}" ;;
  *"-f SSID device wifi list")          cat "${NM_SCAN:-/dev/null}" ;;
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
    NM_SCAN="${NM_SCAN:-$WORK/scan-two}" NM_IFACE="${NM_IFACE:-eth0}" \
    GA_NMCLI="$WORK/nmcli" GA_IP="$WORK/ip" GA_LADDER_SYS_NET="$WORK/sys" \
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
printf 'home-wifi:802-11-wireless:yes\nopenstick-auto:802-11-wireless:yes\nGreenAutarky-Install:802-11-wireless:yes\n' > "$WORK/two-rungs"
printf 'home-wifi:802-11-wireless:yes\n' > "$WORK/one-rung"

#: What K31 actually had when the ladder parked its only uplink (rc42,
#: 2026-09-19): an Ethernet profile with no cable, the loopback, and the mesh
#: WireGuard link — three profiles, no way out.
printf 'home-wifi:802-11-wireless:yes\nWired connection 1:802-3-ethernet:yes\nlo:loopback:yes\nwt0:wireguard:yes\n' > "$WORK/k31-rungs"
#: An Ethernet spare that really is one: cable in, carrier up.
printf 'home-wifi:802-11-wireless:yes\nWired connection 1:802-3-ethernet:yes\n' > "$WORK/eth-spare"

# the SSIDs a scan can see; profiles named here are in range
printf 'openstick-auto\nGreenAutarky-Install\n' > "$WORK/scan-two"
printf '' > "$WORK/scan-none"
mkdir -p "$WORK/sys/eth0" "$WORK/sys/wlan0"
printf '0\n' > "$WORK/sys/eth0/carrier"      # no cable — the K31 case

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

# ── what counts as a rung at all ────────────────────────────────────────────
#
# THE DEVICE CAUGHT THIS ONE. On K31 (rc42, 2026-09-19) the ladder parked the
# only working uplink: it had counted an Ethernet profile with no cable, the
# loopback and the mesh WireGuard link as spare rungs. Three profiles, no way
# out, and the device took itself off the network to reach them. The host-side
# tests could not see it because the fixture had only ever listed profiles that
# were real uplinks — the stub was honest, the WORLD it described was not.
echo "--- a rung needs a medium, not just a profile ---"
rm -rf "$WORK/state" "$WORK/parked" "$WORK/booted"
run limited limited "$WORK/k31-rungs"; run limited limited "$WORK/k31-rungs"; run limited limited "$WORK/k31-rungs"
[ "$(parked_count)" = "0" ] \
    && PASS "cable-less Ethernet, loopback and WireGuard are not spare rungs" \
    || FAIL "K31 case: nothing to fall to" "the ladder parked the only working uplink"

echo "--- an Ethernet spare with a cable IS a rung ---"
rm -rf "$WORK/state" "$WORK/parked" "$WORK/booted"
printf '1\n' > "$WORK/sys/eth0/carrier"
run limited limited "$WORK/eth-spare"; run limited limited "$WORK/eth-spare"; run limited limited "$WORK/eth-spare"
[ "$(parked_count)" = "1" ] && PASS "carrier present -> the dead WiFi is parked" || FAIL "eth spare with carrier" "did not park"
printf '0\n' > "$WORK/sys/eth0/carrier"

echo "--- a WiFi spare that is not in range is not a rung ---"
rm -rf "$WORK/state" "$WORK/parked" "$WORK/booted"
NM_SCAN="$WORK/scan-none" run limited limited "$WORK/two-rungs"
NM_SCAN="$WORK/scan-none" run limited limited "$WORK/two-rungs"
NM_SCAN="$WORK/scan-none" run limited limited "$WORK/two-rungs"
[ "$(parked_count)" = "0" ] \
    && PASS "an SSID nobody can see is not somewhere to fall to" \
    || FAIL "out-of-range WiFi is not a spare" "parked anyway"

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
