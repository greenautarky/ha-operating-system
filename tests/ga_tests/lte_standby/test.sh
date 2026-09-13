#!/bin/sh
# LTE standby OS units — seam S1 (deauth counter), seam S2 (health-gated route)
# and the wlan0 powersave assertion. Runs ON the device (service/enable asserts)
# but the functional asserts also work host-side: each script sources cleanly
# with its GA_*_TEST=1 hook and its pure functions need only sh + coreutils.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

OVL="$SCRIPT_DIR/../../../buildroot-ihost/rootfs-overlay"
EXT="$SCRIPT_DIR/../../../buildroot-external/rootfs-overlay"
DEAUTH="/usr/sbin/ga-wlan0-deauth";            [ -x "$DEAUTH" ] || DEAUTH="$OVL/usr/sbin/ga-wlan0-deauth"
ROUTE="/usr/sbin/ga-lte-standby-route";        [ -x "$ROUTE" ]  || ROUTE="$OVL/usr/sbin/ga-lte-standby-route"
PSAVE="/usr/sbin/ga-wlan0-powersave-assert";   [ -x "$PSAVE" ]  || PSAVE="$OVL/usr/sbin/ga-wlan0-powersave-assert"
PUB="/usr/libexec/ga-share-publish";           [ -x "$PUB" ]    || PUB="$EXT/usr/libexec/ga-share-publish"

suite_start "LTE standby OS units"

run_test "LSB-01" "deauth counter script present + executable" "test -x '$DEAUTH'"
run_test "LSB-02" "standby-route script present + executable"  "test -x '$ROUTE'"
run_test "LSB-03" "powersave-assert script present + executable" "test -x '$PSAVE'"

# NOT a .path unit anywhere (the 2026-09-08 hot-loop finding) for these units.
run_test "LSB-04" "no .path unit ships for the deauth counter or standby route" \
  "! ls '$OVL/etc/systemd/system/'ga-wlan0-deauth.path '$OVL/etc/systemd/system/'ga-lte-standby-route.path 2>/dev/null | grep -q ."

# Service enable — only on a booted device where the units are installed.
if [ -x /usr/sbin/ga-wlan0-deauth ] && command -v systemctl >/dev/null 2>&1; then
  run_test "LSB-05" "deauth counter service enabled" "systemctl is-enabled ga-wlan0-deauth"
  run_test "LSB-06" "standby-route timer enabled"    "systemctl is-enabled ga-lte-standby-route.timer"
  run_test "LSB-07" "powersave-assert service enabled" "systemctl is-enabled ga-wlan0-powersave-assert"
else
  skip_test "LSB-05" "deauth counter service enabled" "no systemctl (host run)"
  skip_test "LSB-06" "standby-route timer enabled" "no systemctl (host run)"
  skip_test "LSB-07" "powersave-assert service enabled" "no systemctl (host run)"
fi

# ── S1: deauth counter functional ──────────────────────────────────────────
TMPD="$(mktemp -d 2>/dev/null || echo /tmp/lsb_$$)"; mkdir -p "$TMPD"
SHARE="$TMPD/ga-wlan0-deauth.json"
BID="$TMPD/boot_id"; echo "aaaaaaaa-1111-2222-3333-444444444444" > "$BID"

# source the counter functions
( export GA_DEAUTH_TEST=1 GA_DEAUTH_SHARE="$SHARE" GA_DEAUTH_LOCK="$SHARE.lock" \
         GA_SHARE_PUBLISH="$PUB" GA_SHARE_STAGE_DIR="$TMPD/stage" \
         GA_DEAUTH_BOOT_ID_PATH="$BID" GA_DEAUTH_IFACE=wlan0
  . "$DEAUTH"
  # a matched Reason-3 line yields "3"; a non-match yields empty
  r="$(deauth_reason 'wlan0: deauthenticated from a0:e0:e4:79:8a:d7 (Reason: 3=DEAUTH_LEAVING)')"
  [ "$r" = "3" ] || { echo "FAIL reason parse: [$r]"; exit 11; }
  [ -z "$(deauth_reason 'wlan0: associated')" ] || { echo "FAIL non-deauth matched"; exit 12; }
  # publish a counter of 5 with a reason breakdown and NO healer marks yet
  publish_counter 5 "$(cat "$BID")" "2026-09-13T10:00:00Z" '"3":5' 3
) || exit 1

run_test "LSB-10" "deauth counter parses the Reason-3 kernel line" "true"  # asserted above (exit 11/12)
run_test "LSB-11" "publish writes reason3_total" "grep -q '\"reason3_total\":5' '$SHARE'"
run_test "LSB-12" "publish writes the boot_id" "grep -q '\"boot_id\":\"aaaaaaaa-1111-2222-3333-444444444444\"' '$SHARE'"
run_test "LSB-13" "publish records last_reason" "grep -q '\"last_reason\":\"3\"' '$SHARE'"
run_test "LSB-14" "the seam file JSON braces balance (equal { and })" \
  "test \"\$(tr -cd '{' < '$SHARE' | wc -c)\" = \"\$(tr -cd '}' < '$SHARE' | wc -c)\" && grep -q '\"healer_marks\":\[' '$SHARE'"

# healer_marks preservation: ga_manager writes a mark; the OS republish must keep it.
python3 - "$SHARE" <<'PY' 2>/dev/null || printf '{"reason3_total":5,"boot_id":"x","healer_marks":["2026-09-13T10:05:00Z"]}\n' > "$SHARE"
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["healer_marks"]=["2026-09-13T10:05:00Z"]; json.dump(d,open(p,"w"))
PY
( export GA_DEAUTH_TEST=1 GA_DEAUTH_SHARE="$SHARE" GA_DEAUTH_LOCK="$SHARE.lock" \
         GA_SHARE_PUBLISH="$PUB" GA_SHARE_STAGE_DIR="$TMPD/stage" GA_DEAUTH_BOOT_ID_PATH="$BID"
  . "$DEAUTH"
  publish_counter 6 "$(cat "$BID")" "2026-09-13T10:06:00Z" '"3":6' 3 )
run_test "LSB-15" "republish PRESERVES ga_manager's healer_marks (two-writer seam)" \
  "grep -q '2026-09-13T10:05:00Z' '$SHARE'"
run_test "LSB-16" "republish updated the counter alongside the preserved marks" \
  "grep -q '\"reason3_total\":6' '$SHARE'"

# reboot: a new boot_id rewrites the field (acceptance: reboot rewrites boot_id)
echo "bbbbbbbb-5555-6666-7777-888888888888" > "$BID"
( export GA_DEAUTH_TEST=1 GA_DEAUTH_SHARE="$SHARE" GA_DEAUTH_LOCK="$SHARE.lock" \
         GA_SHARE_PUBLISH="$PUB" GA_SHARE_STAGE_DIR="$TMPD/stage" GA_DEAUTH_BOOT_ID_PATH="$BID"
  . "$DEAUTH"
  publish_counter 0 "$(cat "$BID")" "" '"3":0' "" )
run_test "LSB-17" "a reboot (new boot_id) rewrites boot_id and resets the count" \
  "grep -q '\"boot_id\":\"bbbbbbbb-5555-6666-7777-888888888888\"' '$SHARE' && grep -q '\"reason3_total\":0' '$SHARE'"

# ── S2: health-gated route functional ──────────────────────────────────────
# On a host `logger` succeeds silently (writes to the journal), so the WARNING
# never reaches stderr for the test to capture. Shadow it with a fake logger
# that echoes its message to stderr — the same text an operator sees in the
# journal on-device.
FAKEBIN="$TMPD/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/logger" <<LGEOF
#!/bin/sh
# strip -t TAG and -p PRIO, append the remaining message to a capture file
# (the real script runs \`logger ... 2>/dev/null\`, so stderr is swallowed —
# on-device the line lands in the journal; here we assert on the file).
while [ \$# -gt 0 ]; do case "\$1" in -t|-p) shift 2;; --) shift; break;; -*) shift;; *) break;; esac; done
echo "\$*" >> "$TMPD/logcap"
LGEOF
chmod +x "$FAKEBIN/logger"

VERDICT="$TMPD/ga-lte-standby.json"
FAKE_STATE="$TMPD/route_state"; : > "$FAKE_STATE"
FAKEIP="$TMPD/fakeip"
cat > "$FAKEIP" <<IPEOF
#!/bin/sh
# fake \`ip\`: -4 route show default dev wlan0 -> prints a default line iff state file says present
case "\$*" in
  *"route show default dev wlan0"*) grep -q present "$FAKE_STATE" && echo "default via 192.168.100.1 dev wlan0 metric 20500" ;;
  *"route add default"*)  echo present > "$FAKE_STATE" ;;
  *"route del default"*)  : > "$FAKE_STATE" ;;
esac
IPEOF
chmod +x "$FAKEIP"

_route() {  # $1 = decision var capture
  ( export GA_ROUTE_TEST=1 GA_STANDBY_VERDICT="$VERDICT" GA_STANDBY_IP="$FAKEIP" GA_STANDBY_STALE_S=600
    . "$ROUTE"; reconcile_once )
}

# usable:true, fresh → route added
printf '{"usable":true,"since":"x","reason":"up","updated_at":"y"}\n' > "$VERDICT"; touch "$VERDICT"
D1="$(_route)"
run_test "LSB-20" "verdict usable:true + fresh -> route added" \
  "test '$D1' = added && grep -q present '$FAKE_STATE'"

# usable:false → route withdrawn
printf '{"usable":false,"since":"x","reason":"no service","updated_at":"y"}\n' > "$VERDICT"; touch "$VERDICT"
D2="$(_route)"
run_test "LSB-21" "verdict usable:false -> route withdrawn" \
  "test '$D2' = withdrawn && ! grep -q present '$FAKE_STATE'"

# add it back, then a MISSING verdict must withdraw AND warn (rule 44)
printf '{"usable":true,"updated_at":"y"}\n' > "$VERDICT"; touch "$VERDICT"; _route >/dev/null
rm -f "$VERDICT"
: > "$TMPD/logcap"
( export GA_ROUTE_TEST=1 GA_STANDBY_VERDICT="$VERDICT" GA_STANDBY_IP="$FAKEIP" PATH="$FAKEBIN:$PATH"; . "$ROUTE"; reconcile_once ) >/dev/null 2>&1
WARN_MISS="$(cat "$TMPD/logcap")"
run_test "LSB-22" "MISSING verdict withdraws the route" "! grep -q present '$FAKE_STATE'"
run_test "LSB-23" "MISSING verdict logs a WARNING naming the substitution (rule 44)" \
  "echo '$WARN_MISS' | grep -qi 'MISSING'"

# stale verdict (old mtime) must withdraw AND warn with the age
printf '{"usable":true,"updated_at":"y"}\n' > "$VERDICT"; touch "$VERDICT"; _route >/dev/null
touch -d '2020-01-01' "$VERDICT" 2>/dev/null || touch -t 202001010000 "$VERDICT"
: > "$TMPD/logcap"
( export GA_ROUTE_TEST=1 GA_STANDBY_VERDICT="$VERDICT" GA_STANDBY_IP="$FAKEIP" GA_STANDBY_STALE_S=600 PATH="$FAKEBIN:$PATH"; . "$ROUTE"; reconcile_once ) >/dev/null 2>&1
WARN_STALE="$(cat "$TMPD/logcap")"
run_test "LSB-24" "STALE verdict (>10min) withdraws the route" "! grep -q present '$FAKE_STATE'"
run_test "LSB-25" "STALE verdict logs a WARNING with the file age (rule 44)" \
  "echo '$WARN_STALE' | grep -qi 'STALE'"

# must-pass: a fresh usable verdict re-adds; the standby metric stays high so
# the primary (eth0, metric ~100) is always preferred — the route never
# competes with the primary.
printf '{"usable":true,"updated_at":"y"}\n' > "$VERDICT"; touch "$VERDICT"
D3="$(_route)"
run_test "LSB-26" "MUST-PASS: usable again -> route re-added at the high standby metric" \
  "test '$D3' = added"
run_test "LSB-27" "MUST-PASS: the standby route metric is high (primary always wins)" \
  "grep -q 'METRIC=.*20500\|METRIC:-20500' '$ROUTE'"

# ── powersave assertion ─────────────────────────────────────────────────────
FAKENM="$TMPD/fakenmcli"
cat > "$FAKENM" <<NMEOF
#!/bin/sh
STATE="$TMPD/ps_state"
case "\$*" in
  *"-f NAME,DEVICE connection show --active"*) echo "openstick-auto:wlan0"; echo "Supervisor:eth0" ;;
  *"-f 802-11-wireless.powersave connection show"*) echo "802-11-wireless.powersave:\$(cat \$STATE 2>/dev/null || echo 1)" ;;
  *"connection modify"*"powersave 2"*) echo 2 > "$TMPD/ps_state" ;;
  *"connection up"*) : ;;
esac
NMEOF
chmod +x "$FAKENM"

echo 1 > "$TMPD/ps_state"   # start with powersave WRONG (1=ignore)
DPS="$( ( export GA_PSAVE_TEST=1 GA_PSAVE_NMCLI="$FAKENM"; . "$PSAVE"; assert_once ) )"
run_test "LSB-30" "powersave wrong (1) -> re-applied to 2 (disabled)" \
  "test '$DPS' = fixed && test \"\$(cat $TMPD/ps_state)\" = 2"
DPS2="$( ( export GA_PSAVE_TEST=1 GA_PSAVE_NMCLI="$FAKENM"; . "$PSAVE"; assert_once ) )"
run_test "LSB-31" "powersave already 2 -> ok, no change" "test '$DPS2' = ok"

# the shipped openstick profile still pins powersave 2 on the created hop
run_test "LSB-32" "openstick auto-connect still sets wifi.powersave 2 on the hop" \
  "grep -q 'wifi.powersave 2' '$OVL/usr/sbin/ga-openstick-autoconnect'"

rm -rf "$TMPD"
suite_end
