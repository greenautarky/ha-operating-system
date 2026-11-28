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
LADDER="$ROOT/buildroot-external/rootfs-overlay/usr/sbin/ga-uplink-ladder"
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
  *"-t -f NAME connection show --active")  cut -d: -f1 "$NM_ACTIVE" ;;
  *"-t -f NAME connection show")           cut -d: -f1 "$NM_PROFILES" ;;
  *"-t -f DEVICE,TYPE,STATE device")       cat "${NM_DEVICES:-/dev/null}" ;;
  *"-f connection.type connection show "*)
      for _a in "$@"; do :; done
      awk -F: -v n="$_a" '$1==n {print "connection.type:" $2; exit}' "$NM_PROFILES" ;;
  *"-g gsm.apn connection show "*)         cat "${NM_APN:-/dev/null}" ;;
  *"-g GENERAL.IP-IFACE device show "*)    echo "${NM_IPIFACE:-ppp0}" ;;
  *"-f NAME,TYPE,AUTOCONNECT connection show") cat "$NM_PROFILES" ;;
  *"-f connection.interface-name connection show "*) echo "connection.interface-name:${NM_IFACE:-eth0}" ;;
  *"-f 802-11-wireless.ssid connection show "*)
      # the ssid of the profile named last on the command line
      for _a in $*; do :; done; echo "802-11-wireless.ssid:${_a}" ;;
  *"-f SSID device wifi list")          cat "${NM_SCAN:-/dev/null}" ;;
  *"-f GENERAL.CONNECTION device show "*) echo "GENERAL.CONNECTION:${NM_CONN:-home-wifi}" ;;
  "device wifi rescan")                 # a rescan refreshes the scan cache
      [ -n "${NM_SCAN_AFTER:-}" ] && cp "$NM_SCAN_AFTER" "$NM_SCAN" ;;
  *) : ;;
esac
STUB
cat > "$WORK/ip" <<'STUB'
#!/bin/sh
cat "$IP_ROUTE"
STUB
cat > "$WORK/mmcli" <<'STUB'
#!/bin/sh
echo "mmcli $*" >> "$NM_LOG"
[ -s "$MM_OUT" ] || exit 1
cat "$MM_OUT"
STUB
# the per-path probe (D2) is its own helper with its own selftest
# (tests/ga_tests/uplink_path_probe); here it is a stub that records the call
cat > "$WORK/path-probe" <<'STUB'
#!/bin/sh
for i; do echo "$i" >> "$PROBE_LOG"; printf '{"iface":"%s","verdict":"%s","ok":0,"of":3,"ms_median":null,"reason":"stub"}\n' "$i" "$PROBE_VERDICT"; done
STUB
chmod +x "$WORK/nmcli" "$WORK/ip" "$WORK/mmcli" "$WORK/path-probe"

run() {   # run <cached> <forced> <profiles-file> [now]
    : > "$WORK/nm.log"
    printf '%s\n' "$1" > "$WORK/cached"
    printf '%s\n' "$2" > "$WORK/forced"
    NM_LOG="$WORK/nm.log" NM_CACHED="$WORK/cached" NM_FORCED="$WORK/forced" \
    NM_ACTIVE="$WORK/active" NM_PROFILES="$3" IP_ROUTE="$WORK/route" \
    NM_DEVICES="${NM_DEVICES:-}" NM_APN="${NM_APN:-}" GA_MMCLI="$WORK/mmcli" MM_OUT="${MM_OUT:-$WORK/mm-none}" \
    GA_BOARD_CONF="$WORK/no-board.conf" GA_LTE_APN_FILE="${GA_LTE_APN_FILE:-$WORK/no-apn-file}" \
    NM_SCAN="${NM_SCAN:-$WORK/scan-two}" NM_IFACE="${NM_IFACE:-eth0}" NM_SCAN_AFTER="${NM_SCAN_AFTER:-}" \
    GA_LADDER_RESCAN_WAIT_S=0 GA_LADDER_TRIED_DIR="$WORK/tried" \
    GA_NMCLI="$WORK/nmcli" GA_IP="$WORK/ip" GA_LADDER_SYS_NET="$WORK/sys" \
    GA_LADDER_STATE="$WORK/state" GA_LADDER_BOOT_MARK="$WORK/booted" \
    GA_LADDER_PARK_DIR="$WORK/parked" GA_LADDER_STATUS="$WORK/status.json" \
    GA_SHARE_PUBLISH="$ROOT/buildroot-external/rootfs-overlay/usr/libexec/ga-share-publish" \
    GA_SHARE_STAGE_DIR="$WORK/stage" \
    GA_UPLINK_PATH_PROBE="$WORK/path-probe" GA_UPLINK_PATHS_DIR="$WORK/paths" NM_CONN="${NM_CONN:-}" \
    PROBE_VERDICT="${PROBE_VERDICT:-clean}" PROBE_LOG="$WORK/probe.log" \
    GA_LADDER_NOW="${4:-1000000}" GA_LADDER_COOLDOWN_S=900 \
      sh "$LADDER" >/dev/null 2>&1
}
rescans() { grep -c "device wifi rescan" "$WORK/nm.log"; }
nmlog_all() { cat "$WORK/nm.all" 2>/dev/null; }
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


# ── Odoo #2112: a device without internet never stops looking ───────────────
#
# K31, 2026-11-16: hours on a GA dongle Wi-Fi with no data while the bench
# Wi-Fi was in range. The spare test read the NM scan CACHE, the cache had aged
# the SSID out, and the ladder said "LAST uplink - keeping it" for ever.
printf 'openstick-auto:wlan0\n' > "$WORK/active"
printf 'openstick-auto:802-11-wireless:yes\nGreenAutarky-Install:802-11-wireless:yes\nWired connection 1:802-3-ethernet:yes\nlo:loopback:yes\nwt0:wireguard:yes\n' > "$WORK/k31-now"
printf 'GA-5320\n' > "$WORK/scan-stale"
printf 'GA-5320\nGreenAutarky-Install\n' > "$WORK/scan-fresh"
reset_state() { rm -rf "$WORK/state" "$WORK/state.switch" "$WORK/state.rescan" "$WORK/parked" "$WORK/booted" "$WORK/tried"; : > "$WORK/nm.all"; }
tick() { run "$1" "$1" "$2" "$3"; cat "$WORK/nm.log" >> "$WORK/nm.all"; }
firstline() { grep -n "$1" "$WORK/nm.all" | head -1 | cut -d: -f1; }

echo "--- K31 replay: stale scan cache, SSID in range -> rescan, then park + move ---"
reset_state
cp "$WORK/scan-stale" "$WORK/scan-live"
for t in 1000120 1000240 1000360; do NM_SCAN="$WORK/scan-live" NM_SCAN_AFTER="$WORK/scan-fresh" tick limited "$WORK/k31-now" $t; done
[ "$(parked_count)" = "1" ] && PASS "stale cache: the dead dongle Wi-Fi is parked after the rescan found the bench SSID" \
    || FAIL "K31 stale cache parks" "parks=$(parked_count) (0 = the 2026-11-16 outage)"
r=$(firstline "device wifi rescan"); d=$(firstline "connection down openstick-auto")
[ -n "$r" ] && [ -n "$d" ] && [ "$r" -lt "$d" ] && PASS "the rescan is logged BEFORE the park" || FAIL "rescan precedes park" "rescan@${r:-none} down@${d:-none}"
grep -q "connection up GreenAutarky-Install" "$WORK/nm.all" && PASS "the found profile is brought up explicitly (bounded)" || FAIL "explicit up of the candidate" "missing"
grep -q '"spare":"GreenAutarky-Install"' "$WORK/status.json" || grep -q '"rung":"switching"' "$WORK/status.json" \
    && PASS "status file reports the switch" || FAIL "status after switch" "$(cat "$WORK/status.json")"

echo "--- offline on the last rung, a known SSID appears later -> found, moved ---"
reset_state
printf 'GA-5320\n' > "$WORK/scan-live"
for t in 1000120 1000240 1000360; do NM_SCAN="$WORK/scan-live" NM_SCAN_AFTER="$WORK/scan-live" tick limited "$WORK/k31-now" $t; done
[ "$(parked_count)" = "0" ] && PASS "nothing in range: the last rung is kept" || FAIL "last rung kept" "parked"
[ "$(rescans)" -ge 1 ] && PASS "it rescanned before saying so" || FAIL "rescan before giving up" "none"
grep -q '"last_rung":true' "$WORK/status.json" && grep -q '"searching":true' "$WORK/status.json" && grep -q '"last_rescan":"[0-9]' "$WORK/status.json" \
    && PASS "status says last_rung, searching and when it last rescanned" || FAIL "status diagnostics" "$(cat "$WORK/status.json")"
NM_SCAN="$WORK/scan-live" NM_SCAN_AFTER="$WORK/scan-live" tick limited "$WORK/k31-now" 1000480
[ "$(rescans)" -ge 1 ] && PASS "it keeps rescanning on every offline tick" || FAIL "rescan every tick while offline" "none on tick 4"
[ "$(parked_count)" = "0" ] || FAIL "still nothing to move to" "parked"
NM_SCAN="$WORK/scan-live" NM_SCAN_AFTER="$WORK/scan-fresh" tick limited "$WORK/k31-now" 1000600   # the bench Wi-Fi switches on
[ "$(parked_count)" = "1" ] && grep -q "connection up GreenAutarky-Install" "$WORK/nm.log" \
    && PASS "the SSID that appeared later is found and used" || FAIL "late SSID found" "parks=$(parked_count)"

echo "--- no spare is logged loudly with the reason ---"
reset_state
printf 'GA-5320\n' > "$WORK/scan-live"
: > "$WORK/logger.out"
printf '#!/bin/sh\necho "$*" >> "%s/logger.out"\n' "$WORK" > "$WORK/logger"; chmod +x "$WORK/logger"
for t in 1000120 1000240 1000360; do PATH="$WORK:$PATH" NM_SCAN="$WORK/scan-live" tick limited "$WORK/k31-now" $t; done
grep -q "GreenAutarky-Install: SSID not in range" "$WORK/logger.out" && grep -q "Wired connection 1: no carrier" "$WORK/logger.out" \
    && grep -q "daemon.warning" "$WORK/logger.out" \
    && PASS "rejected candidates are logged at warning with the reason" || FAIL "loud diagnostics" "$(cat "$WORK/logger.out")"

echo "--- a healthy device never rescans or probes ---"
reset_state
for t in 1000120 1000240 1000360 1000480; do NM_SCAN="$WORK/scan-stale" tick full full "$WORK/k31-now" $t; done
{ [ "$(rescans)" = "0" ] && [ "$(probed)" = "0" ] && ! grep -qE "rescan|connectivity check|connection up" "$WORK/nm.all"; } \
    && PASS "four healthy ticks: no rescan, no probe, no connection up" || FAIL "healthy is free" "$(tr '\n' ';' < "$WORK/nm.all")"

echo "--- a candidate that is not full either: previous restored, no flapping ---"
reset_state
printf 'home-wifi:wlan0\n' > "$WORK/active"
n=0; t=1000000
while [ $n -lt 12 ]; do
    n=$((n+1)); t=$((t+120)); NM_SCAN="$WORK/scan-two" tick limited "$WORK/two-rungs" $t
done
ups=$(grep -c "connection up openstick-auto" "$WORK/nm.all")
[ "$ups" -ge 1 ] && [ "$ups" -le 2 ] && PASS "12 dead ticks: the candidate was tried at most twice (cooldown holds), got $ups" || FAIL "no flapping" "ups=$ups"
grep -q "connection up home-wifi" "$WORK/nm.all" && PASS "the previous rung was restored when the candidate was not full" || FAIL "fallback to previous" "never restored"
grep -q "connection modify home-wifi connection.autoconnect yes" "$WORK/nm.all" && PASS "and it is un-parked, so NM may keep it" || FAIL "previous unparked" "missing"
printf 'home-wifi:wlan0\n' > "$WORK/active"

# ── Odoo #2176: the built-in modem rung (DSGW-210) ───────────────────────────
#
# The ladder already listed any `gsm` profile as a rung with no check that a
# modem exists. On a board with a soldered modem that means a device without a
# SIM parks its working Ethernet for a rung that cannot carry a packet. And the
# modem state was invisible to ga_manager (add-on container: no mmcli, no
# host interfaces). Everything below is gated on GA_BUILTIN_MODEM=1 (board file);
# the iHost block pins that it stays as it was.
LTE="DSGW-210 LTE"
printf 'Wired connection 1:end0\n' > "$WORK/active"; printf 'default dev end0 scope link\n' > "$WORK/route"
printf 'Wired connection 1:802-3-ethernet:yes\n%s:gsm:yes\nlo:loopback:yes\n' "$LTE" > "$WORK/dsgw-profiles"
printf 'end0:ethernet:connected\nttyUSB2:gsm:disconnected\nlo:loopback:unmanaged\n' > "$WORK/dev-modem-ok"
printf 'end0:ethernet:connected\nlo:loopback:unmanaged\n' > "$WORK/dev-no-modem"
printf 'end0:ethernet:connected\nttyUSB2:gsm:unavailable\nlo:loopback:unmanaged\n' > "$WORK/dev-no-sim"
printf 'end0:ethernet:connected\nttyUSB2:gsm:connected\nlo:loopback:unmanaged\n' > "$WORK/dev-modem-up"
cat > "$WORK/mm-reg" <<'MM'
modem.generic.state                      : registered
modem.generic.state-failed-reason        : --
modem.3gpp.operator-name                 : TestNet
modem.generic.access-technologies.value[1] : lte
modem.generic.signal-quality.value       : 64
modem.generic.equipment-identifier       : 000000000000000
MM
cat > "$WORK/mm-nosim" <<'MM'
modem.generic.state                      : failed
modem.generic.state-failed-reason        : sim-missing
MM
: > "$WORK/mm-none"
mkdir -p "$WORK/sys/end0"; printf '1\n' > "$WORK/sys/end0/carrier"
dsgw_env() { export GA_BUILTIN_MODEM=1 NM_IFACE=end0; }
dsgw_off() { unset GA_BUILTIN_MODEM; export NM_IFACE=eth0; }
dead3() { for t in 1000120 1000240 1000360; do NM_DEVICES="$1" tick limited "$WORK/dsgw-profiles" $t; done; }
parkfile() { cat "$WORK/parked/$1" 2>/dev/null; }
mtick() {   # mtick <verdict> <now> [devices-file]: a tick on the DSGW with a registered modem
    MM_OUT="$WORK/mm-reg" NM_DEVICES="${3:-$WORK/dev-modem-up}" tick "$1" "$WORK/dsgw-profiles" "$2"
}

echo "--- DSGW: Ethernet dead, modem usable -> Ethernet parked short, modem brought up ---"
reset_state; dsgw_env
MM_OUT="$WORK/mm-reg" dead3 "$WORK/dev-modem-ok"
[ "$(parked_count)" = "1" ] && [ -f "$WORK/parked/Wired connection 1" ] && PASS "3 strikes park the dead Ethernet" || FAIL "park eth on modem fallback" "parked=$(ls "$WORK/parked" 2>/dev/null)"
[ "$(parkfile 'Wired connection 1')" = "1000960" ] && PASS "falling to the modem parks for the SHORT modem-back window (600 s), not 900 s" || FAIL "short park for modem fallback" "until=$(parkfile 'Wired connection 1')"
grep -q "connection up $LTE" "$WORK/nm.all" && PASS "the modem profile is brought up explicitly (bounded)" || FAIL "modem up" "$(tr '\n' ';' < "$WORK/nm.all")"

echo "--- DSGW: no modem device -> not a rung, Ethernet is the last rung and is kept ---"
reset_state; dsgw_env
: > "$WORK/logger.out"; printf '#!/bin/sh\necho "$*" >> "%s/logger.out"\n' "$WORK" > "$WORK/logger"; chmod +x "$WORK/logger"
for t in 1000120 1000240 1000360; do PATH="$WORK:$PATH" NM_DEVICES="$WORK/dev-no-modem" tick limited "$WORK/dsgw-profiles" $t; done
[ "$(parked_count)" = "0" ] && PASS "a board whose modem is missing does not park its working uplink" || FAIL "absent modem is no rung" "parked $(ls "$WORK/parked")"
grep -q "$LTE: no usable modem" "$WORK/logger.out" && PASS "and says why, at warning" || FAIL "loud rejection" "$(cat "$WORK/logger.out")"

echo "--- DSGW: modem present but no SIM (unavailable) -> not a rung ---"
reset_state; dsgw_env
MM_OUT="$WORK/mm-nosim" dead3 "$WORK/dev-no-sim"
[ "$(parked_count)" = "0" ] && PASS "a SIM-less modem is not somewhere to fall to" || FAIL "no-SIM modem is no rung" "parked"

echo "--- DSGW: back to Ethernet when its park window ends, verified, modem restored if it is still dead ---"
reset_state; dsgw_env
printf '%s:ppp0\n' "$LTE" > "$WORK/active"; printf 'default dev ppp0 scope link\n' > "$WORK/route"
mkdir -p "$WORK/parked"; echo 1000500 > "$WORK/parked/Wired connection 1"; : > "$WORK/booted"
mtick full 1000400
{ [ -f "$WORK/parked/Wired connection 1" ] && ! grep -q "connection up Wired connection 1" "$WORK/nm.all"; } && PASS "before the window ends Ethernet stays parked (no flapping)" || FAIL "park holds" "released early"
mtick full 1000600
grep -q "connection up Wired connection 1" "$WORK/nm.all" && [ ! -f "$WORK/parked/Wired connection 1" ] && PASS "window over: Ethernet unparked and brought up through the verified switch" || FAIL "return to Ethernet" "$(tr '\n' ';' < "$WORK/nm.all")"
[ -f "$WORK/state.switch" ] && PASS "the switch is recorded so the next tick can verify it" || FAIL "switch recorded" "no record"
printf 'Wired connection 1:end0\n' > "$WORK/active"; printf 'default dev end0 scope link\n' > "$WORK/route"
mtick none 1000800
grep -q "connection up $LTE" "$WORK/nm.all" && PASS "Ethernet came back but is not full: the modem is restored" || FAIL "modem restored" "$(tr '\n' ';' < "$WORK/nm.all")"
[ -f "$WORK/parked/Wired connection 1" ] && PASS "and the dead Ethernet is parked again, so it cannot hold the default route" || FAIL "eth re-parked" "not parked"
printf 'Wired connection 1:end0\n' > "$WORK/active"

echo "--- DSGW: Ethernet back and full -> stays, nothing is switched back and forth ---"
reset_state; dsgw_env
printf '%s:ppp0\n' "$LTE" > "$WORK/active"; printf 'default dev ppp0 scope link\n' > "$WORK/route"
mkdir -p "$WORK/parked"; echo 1000500 > "$WORK/parked/Wired connection 1"; : > "$WORK/booted"
mtick full 1000600
printf 'Wired connection 1:end0\n' > "$WORK/active"; printf 'default dev end0 scope link\n' > "$WORK/route"
mtick full 1000720
[ "$(parked_count)" = "0" ] && [ ! -f "$WORK/state.switch" ] && ! grep -q "connection up $LTE" "$WORK/nm.log" && PASS "verified full: switch record cleared, modem left alone" || FAIL "stay on Ethernet" "$(tr '\n' ';' < "$WORK/nm.log")"
[ "$(probed)" = "1" ] && PASS "the verifying tick asked NM for a FRESH verdict (the cache may still describe the modem)" || FAIL "fresh verdict after a switch" "probes=$(probed)"
mtick full 1000840
[ "$(probed)" = "0" ] && PASS "and the next healthy tick is free again (no probe)" || FAIL "healthy is free after verification" "probes=$(probed)"

echo "--- DSGW: status carries the modem state for ga_manager ---"
reset_state; dsgw_env
mtick full 1000120 "$WORK/dev-modem-ok"
if jq -e '.modem.present==true and .modem.registered==true and .modem.bearer_up==false and .modem.iface=="ppp0" and .modem.tech=="lte" and .modem.signal==64 and .modem.operator=="TestNet"' "$WORK/status.json" >/dev/null 2>&1
then PASS "present, registered, bearer down, interface, tech, signal, operator"; else FAIL "modem block" "$(cat "$WORK/status.json")"; fi
grep -q "000000000000000" "$WORK/status.json" && FAIL "no identifiers in the status" "IMEI leaked" || PASS "no IMEI / ICCID / number in the status file"
mtick full 1000240
jq -e '.modem.bearer_up==true and .modem.registered==true' "$WORK/status.json" >/dev/null 2>&1 && PASS "bearer up when NM says the modem device is connected" || FAIL "bearer_up" "$(cat "$WORK/status.json")"
MM_OUT="$WORK/mm-nosim" NM_DEVICES="$WORK/dev-no-sim" tick full "$WORK/dsgw-profiles" 1000360
jq -e '.modem.present==true and .modem.registered==false and .modem.state=="failed" and .modem.failed_reason=="sim-missing"' "$WORK/status.json" >/dev/null 2>&1 && PASS "SIM missing: present, not registered, reason carried" || FAIL "sim-missing block" "$(cat "$WORK/status.json")"
MM_OUT="$WORK/mm-none" NM_DEVICES="$WORK/dev-no-modem" tick full "$WORK/dsgw-profiles" 1000480
jq -e '.modem.present==false and .modem.registered==false and .modem.bearer_up==false' "$WORK/status.json" >/dev/null 2>&1 && PASS "no modem at all: present=false" || FAIL "absent modem block" "$(cat "$WORK/status.json")"

echo "--- DSGW: the APN is configuration (file > board default > auto) ---"
reset_state; dsgw_env
printf 'apn.test.invalid\n' > "$WORK/apn-file"; : > "$WORK/apn-have"
GA_LTE_APN_FILE="$WORK/apn-file" NM_APN="$WORK/apn-have" mtick full 1000120 "$WORK/dev-modem-ok"
grep -q "connection modify $LTE gsm.apn apn.test.invalid gsm.auto-config no" "$WORK/nm.log" && PASS "APN from the boot-partition file is applied to the profile" || FAIL "apn from file" "$(tr '\n' ';' < "$WORK/nm.log")"
printf 'apn.test.invalid\n' > "$WORK/apn-have"
GA_LTE_APN_FILE="$WORK/apn-file" NM_APN="$WORK/apn-have" mtick full 1000240 "$WORK/dev-modem-ok"
! grep -q "connection modify" "$WORK/nm.log" && PASS "unchanged APN: no rewrite, no re-dial (idempotent)" || FAIL "apn idempotent" "$(tr '\n' ';' < "$WORK/nm.log")"
printf 'bad apn;rm -rf /\n' > "$WORK/apn-file"
GA_LTE_APN_FILE="$WORK/apn-file" NM_APN="$WORK/apn-have" mtick full 1000360 "$WORK/dev-modem-ok"
grep -q "gsm.auto-config yes" "$WORK/nm.log" && ! grep -q "rm -rf" "$WORK/nm.log" && PASS "an invalid file is ignored, never passed to nmcli; falls to auto" || FAIL "invalid apn ignored" "$(tr '\n' ';' < "$WORK/nm.log")"
rm -f "$WORK/apn-file"; : > "$WORK/apn-have"
GA_LTE_APN_DEFAULT=iot.board.invalid NM_APN="$WORK/apn-have" mtick full 1000480 "$WORK/dev-modem-ok"
grep -q "gsm.apn iot.board.invalid" "$WORK/nm.log" && PASS "no file: the board default (GA_LTE_APN_DEFAULT) is used" || FAIL "board default apn" "$(tr '\n' ';' < "$WORK/nm.log")"
printf '%s:ppp0\n' "$LTE" > "$WORK/active"
printf 'apn.test.invalid\n' > "$WORK/apn-file"; : > "$WORK/apn-have"
GA_LTE_APN_FILE="$WORK/apn-file" NM_APN="$WORK/apn-have" mtick full 1000600
grep -q "connection up $LTE" "$WORK/nm.log" && PASS "a profile that is up is re-dialled so the new APN takes effect" || FAIL "re-dial on apn change" "$(tr '\n' ';' < "$WORK/nm.log")"
printf 'Wired connection 1:end0\n' > "$WORK/active"; dsgw_off

echo "--- iHost: a gsm profile is still a rung, nothing modem-related runs (must stay as it was) ---"
reset_state; dsgw_off
printf 'Wired connection 1:eth0\n' > "$WORK/active"; printf 'default dev eth0 scope link\n' > "$WORK/route"
printf '1\n' > "$WORK/sys/eth0/carrier"
for t in 1000120 1000240 1000360; do NM_DEVICES="$WORK/dev-no-modem" MM_OUT="$WORK/mm-reg" tick limited "$WORK/dsgw-profiles" $t; done
[ -f "$WORK/parked/Wired connection 1" ] && [ "$(parkfile 'Wired connection 1')" = "1001260" ] && grep -q "connection up $LTE" "$WORK/nm.all" \
    && PASS "iHost: the gsm profile is a spare as before, the park uses the normal 900 s cooldown" || FAIL "iHost unchanged" "parked=$(ls "$WORK/parked" 2>/dev/null) until=$(parkfile 'Wired connection 1')"
! grep -q "^mmcli" "$WORK/nm.all" && ! grep -qE "gsm.apn|DEVICE,TYPE,STATE" "$WORK/nm.all" && ! grep -q '"modem"' "$WORK/status.json" \
    && PASS "iHost: no mmcli, no APN write, no device query, no modem key in the status file" || FAIL "iHost inert" "$(grep -E 'mmcli|gsm.apn|DEVICE,TYPE' "$WORK/nm.all" | head -3) $(cat "$WORK/status.json")"
printf '0\n' > "$WORK/sys/eth0/carrier"
printf 'home-wifi:wlan0\n' > "$WORK/active"; printf 'default dev wlan0 scope link\n' > "$WORK/route"

echo "--- DSGW image wiring: board file, NM profile and ladder agree (reachability, not just logic) ---"
DSGW_OVL="$ROOT/buildroot-dsgw210/board/dusun/dsgw210/rootfs-overlay"
KEYF="$DSGW_OVL/usr/lib/NetworkManager/system-connections/dsgw210-lte.nmconnection"
BCONF="$DSGW_OVL/usr/share/ga-board.conf"
[ -r "$KEYF" ] && [ -r "$BCONF" ] || { FAIL "DSGW image files exist" "missing $KEYF or $BCONF"; }
KEY_ID=$(sed -n 's/^id=//p' "$KEYF" | head -1)
BC_PROFILE=$(env -u GA_LTE_PROFILE sh -c '. "$1"; echo "$GA_LTE_PROFILE"' _ "$BCONF")
[ -n "$KEY_ID" ] && [ "$KEY_ID" = "$BC_PROFILE" ] && PASS "GA_LTE_PROFILE in ga-board.conf is the id= of the shipped NM profile ('$KEY_ID')" || FAIL "profile name coupling" "keyfile id='$KEY_ID' board file='$BC_PROFILE'"
[ "$(env -u GA_BUILTIN_MODEM sh -c '. "$1"; echo "$GA_BUILTIN_MODEM"' _ "$BCONF")" = 1 ] && PASS "the DSGW board file turns the built-in modem on" || FAIL "GA_BUILTIN_MODEM set on the DSGW" "not 1"
! grep -qE '^apn=' "$KEYF" && grep -q '^auto-config=true' "$KEYF" && PASS "the shipped profile pins no APN and auto-configures from the SIM" || FAIL "no pinned APN in the image" "$(grep -nE '^apn=|^auto-config' "$KEYF")"
reset_state
printf 'Wired connection 1:end0\n' > "$WORK/active"; printf 'default dev end0 scope link\n' > "$WORK/route"
NM_IFACE=end0 NM_DEVICES="$WORK/dev-modem-ok" MM_OUT="$WORK/mm-reg" tick full "$WORK/dsgw-profiles" 1000120
# the real board file, no GA_BUILTIN_MODEM in the environment: the ladder must pick it up itself
: > "$WORK/nm.log"
env -u GA_BUILTIN_MODEM NM_LOG="$WORK/nm.log" NM_CACHED="$WORK/cached" NM_FORCED="$WORK/forced" NM_ACTIVE="$WORK/active" NM_PROFILES="$WORK/dsgw-profiles" \
    IP_ROUTE="$WORK/route" NM_SCAN="$WORK/scan-two" NM_IFACE=end0 NM_DEVICES="$WORK/dev-modem-ok" GA_MMCLI="$WORK/mmcli" MM_OUT="$WORK/mm-reg" \
    GA_BOARD_CONF="$BCONF" GA_LTE_APN_FILE="$WORK/no-apn-file" GA_LADDER_RESCAN_WAIT_S=0 GA_LADDER_TRIED_DIR="$WORK/tried" \
    GA_NMCLI="$WORK/nmcli" GA_IP="$WORK/ip" GA_LADDER_SYS_NET="$WORK/sys" GA_LADDER_STATE="$WORK/state" GA_LADDER_BOOT_MARK="$WORK/booted" \
    GA_LADDER_PARK_DIR="$WORK/parked" GA_LADDER_STATUS="$WORK/status.json" GA_SHARE_PUBLISH="$ROOT/buildroot-external/rootfs-overlay/usr/libexec/ga-share-publish" \
    GA_SHARE_STAGE_DIR="$WORK/stage" GA_LADDER_NOW=1000240 sh "$LADDER" >/dev/null 2>&1
jq -e '.modem.present==true' "$WORK/status.json" >/dev/null 2>&1 && PASS "run with the REAL DSGW board file only: the status carries the modem object" || FAIL "board file reaches the ladder" "$(cat "$WORK/status.json")"

echo "--- DSGW: SIM inserted after boot -> modem power-cycle (Odoo #2176) ---"
# Measured on DUT2 2026-11-18: BG96 SIM detection is off (QSIMDET 0,0), ModemManager
# keeps the modem failed/sim-missing until the modem is power-cycled.
reset_state; rm -f "$WORK/state.simmissing"; dsgw_env
export GA_MODEM_RESET_PORT="$WORK/at-port" GA_LADDER_SIM_GRACE_S=180 GA_LADDER_SIM_RESET_EVERY_S=1800 GA_LADDER_SIM_RESET_MAX=2
stick() { : > "$WORK/at-port"; MM_OUT="${2:-$WORK/mm-nosim}" NM_DEVICES="$WORK/dev-no-sim" tick full "$WORK/dsgw-profiles" "$1"; }
wrote() { grep -q 'AT+CFUN=1,1' "$WORK/at-port" 2>/dev/null; }
stick 2000000; ! wrote && [ -s "$WORK/state.simmissing" ] && PASS "sim-missing inside the grace period: no reset, first sighting recorded" || FAIL "grace" "$(cat "$WORK/at-port" "$WORK/state.simmissing" 2>&1)"
stick 2000200; wrote && PASS "sim-missing past the grace period: AT+CFUN=1,1 written to the reset port" || FAIL "reset after grace" "$(cat "$WORK/state.simmissing" 2>&1)"
stick 2000400; ! wrote && PASS "no second reset inside SIM_RESET_EVERY_S" || FAIL "rate limit" "reset repeated"
stick 2002100; wrote && PASS "second reset after SIM_RESET_EVERY_S" || FAIL "second reset" "$(cat "$WORK/state.simmissing" 2>&1)"
stick 2004000; ! wrote && grep -q giveup "$WORK/state.simmissing" && PASS "cap reached (SIM_RESET_MAX=2): no third reset, give-up recorded" || FAIL "cap" "$(cat "$WORK/state.simmissing" 2>&1)"
stick 2006000; ! wrote && PASS "after give-up: still no reset" || FAIL "give-up holds" "reset after give-up"
stick 2006100 "$WORK/mm-reg"; [ ! -e "$WORK/state.simmissing" ] && ! wrote && PASS "SIM read again (registered): record cleared, no reset" || FAIL "clear on recovery" "$(cat "$WORK/state.simmissing" 2>&1)"
unset GA_MODEM_RESET_PORT; rm -f "$WORK/state.simmissing"
stick 2010000; stick 2010200; ! wrote && PASS "no reset port configured: nothing written (logged instead)" || FAIL "no port" "wrote without a port"
export GA_MODEM_RESET_PORT="$WORK/at-port"; rm -f "$WORK/state.simmissing"; dsgw_off
stick 2020000; stick 2020200; ! wrote && [ ! -e "$WORK/state.simmissing" ] && PASS "iHost (no built-in modem): never resets" || FAIL "iHost inert" "$(cat "$WORK/at-port" 2>&1)"
unset GA_MODEM_RESET_PORT GA_LADDER_SIM_GRACE_S GA_LADDER_SIM_RESET_EVERY_S GA_LADDER_SIM_RESET_MAX
grep -q 'GA_MODEM_RESET_PORT:=/dev/lte-ppp' "$BCONF" && PASS "the DSGW board file names the reset port (/dev/lte-ppp = USB interface 03)" || FAIL "board reset port" "missing in $BCONF"


# ── D2 per-path probe (Odoo #2201): REPORT ONLY ─────────────────────────────
rm -rf "$WORK/paths" "$WORK/parked" "$WORK/state"*; : > "$WORK/probe.log"
printf 'default dev wlan0 scope link\n' > "$WORK/route"; printf 'home-wifi:wlan0\n' > "$WORK/active"
PROBE_VERDICT=dead run full full "$WORK/two-rungs" 1000000
if grep -q '"paths":\[{"iface":"wlan0","verdict":"dead"' "$WORK/status.json"; then PASS "D2: ga-uplink.json carries the per-path result (paths[])"; else FAIL "D2 paths in status" "$(cat "$WORK/status.json")"; fi
if [ "$(parked_count)" = 0 ] && ! grep -q "connection up\|connection down\|autoconnect no" "$WORK/nm.log"; then PASS "D2 is report-only: a dead path probe with NM 'full' parks and switches NOTHING"; else FAIL "D2 report-only" "$(cat "$WORK/nm.log")"; fi
[ "$(probed)" = 0 ] && PASS "D2 does not add an NM connectivity probe on a healthy device" || FAIL "D2 extra NM probe" "$(probed)"
: > "$WORK/probe.log"; run full full "$WORK/two-rungs" 1000300
[ ! -s "$WORK/probe.log" ] && PASS "D2: not due again 300 s later (every 600 s)" || FAIL "D2 cadence" "$(cat "$WORK/probe.log")"
run full full "$WORK/two-rungs" 1000600
grep -qx wlan0 "$WORK/probe.log" && PASS "D2: probed again after 600 s" || FAIL "D2 re-probe" "$(cat "$WORK/probe.log")"
# metered: the SIM dongle's Wi-Fi (connection named GA-<digits>) only every 1800 s
rm -rf "$WORK/paths"; : > "$WORK/probe.log"
NM_CONN=GA-4392 run full full "$WORK/two-rungs" 2000000
NM_CONN=GA-4392 run full full "$WORK/two-rungs" 2000600
NM_CONN=GA-4392 run full full "$WORK/two-rungs" 2001200
[ "$(grep -c . "$WORK/probe.log")" = 1 ] && PASS "D2: the SIM dongle path is probed once in 1200 s (not every 600 s)" || FAIL "D2 metered cadence" "$(grep -c . "$WORK/probe.log") probes"
NM_CONN=GA-4392 run full full "$WORK/two-rungs" 2001800
[ "$(grep -c . "$WORK/probe.log")" = 2 ] && PASS "D2: ...and again after 1800 s" || FAIL "D2 metered re-probe" "$(grep -c . "$WORK/probe.log") probes"
grep -q '"connection":"GA-4392"' "$WORK/status.json" && PASS "D2: each path names its connection" || FAIL "D2 connection name" "$(cat "$WORK/status.json")"

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
