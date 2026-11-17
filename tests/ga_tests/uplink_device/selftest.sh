#!/bin/sh
# Host-side selftest of uplink_device/test.sh: the LIVE suite against fixture status files
# (the REAL ladder writes the same schema - one fixture is produced by the live ga-uplink-ladder
# itself, so the suite and the writer cannot drift apart), a stub systemctl/journalctl, and the
# installed-script paths pointed at the tree. Must-PASS: a healthy iHost and a healthy DSGW.
# Must-FAIL: old schema, wrong types, stale file, a rescan on a healthy device, a back-off
# file that is garbage, an auto-connect script that curls. Must-SKIP: DSGW OpenStick rows,
# UPL-05 on an unhealthy device.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/devsuite_selftest.sh"
ds_init
OVL="$DS_ROOT/../buildroot-external/rootfs-overlay"
LADDER="$OVL/usr/sbin/ga-uplink-ladder"
OSC="$DS_ROOT/../buildroot-ihost/rootfs-overlay/usr/sbin/ga-openstick-autoconnect"
[ -s "$LADDER" ] && [ -s "$OSC" ] || { echo "FATAL: ladder or auto-connect script missing in the tree"; exit 2; }
NOW=1800000000
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

cat > "$W/bin/systemctl" <<'STUB'
#!/bin/sh
case "$*" in
  is-active*) echo "${FAKE_TIMER:-active}" ;;
  *NextElapseUSecMonotonic*) echo 90000000 ;;
esac
STUB
cat > "$W/bin/journalctl" <<'STUB'
#!/bin/sh
cat "${FAKE_JOURNAL:-/dev/null}"
STUB
chmod +x "$W/bin/"*

status() {   # status <verdict> <strikes> <last_rung> <searching> <last_rescan> <age-s>
  printf '{"rung":"eth0","verdict":"%s","strikes":%s,"parked":"","spare":"","last_rung":%s,"searching":%s,"last_rescan":"%s","updated_at":"%s"}\n' \
    "$1" "$2" "$3" "$4" "$5" "$(iso $((NOW - $6)))" > "$W/status.json"
}
run() { ds_run uplink_device GA_UPLD_NOW=$NOW GA_UPLD_STATUS="$W/status.json" GA_UPLD_LADDER="$LADDER" GA_UPLD_OSC="$OSC" \
  GA_UPLD_BACKOFF="$W/backoff" GA_UPLD_BOARD="${BOARD:-ihost}" GA_DEVT_WAIT_S=1 "$@"; }
good() { status full 0 false false "" 30; rm -f "$W/backoff" "$W/journal"; BOARD=ihost; }

echo "== known-good iHost: everything green"
good; run
for i in UPL-01 UPL-02 UPL-03 UPL-04 UPL-04b UPL-04c UPL-05 UPL-10 UPL-11 UPL-12 UPL-13; do ds_expect "$i" PASS "healthy iHost"; done

echo "== known-good DSGW-210: ladder rows green, OpenStick rows SKIP with the reason"
good; BOARD=dsgw210; run
for i in UPL-04 UPL-04b UPL-05; do ds_expect "$i" PASS "healthy DSGW"; done
for i in UPL-10 UPL-11 UPL-12 UPL-13; do ds_expect "$i" SKIP "no OpenStick auto-connect on the DSGW-210"; done

echo "== the schema the LIVE ladder writes passes UPL-04 (producer and consumer, one change)"
cat > "$W/bin/nmcli" <<'STUB'
#!/bin/sh
case "$*" in *"-f CONNECTIVITY general status") echo full ;; "networking connectivity check") echo full ;; esac
STUB
printf '#!/bin/sh\ncat > "$1"\n' > "$W/bin/pub"; chmod +x "$W/bin/nmcli" "$W/bin/pub"
GA_NMCLI="$W/bin/nmcli" GA_IP="$W/bin/nmcli" GA_SHARE_PUBLISH="$W/bin/pub" GA_LADDER_STATUS="$W/status.json" GA_LADDER_STATE="$W/lstate" \
  GA_LADDER_BOOT_MARK="$W/booted" GA_LADDER_PARK_DIR="$W/park" GA_LADDER_TRIED_DIR="$W/tried" sh "$LADDER" >/dev/null 2>&1
run
ds_expect UPL-04 PASS "status file written by the live ga-uplink-ladder"
ds_expect UPL-04b PASS "...with the types the suite expects"

echo "== must-flag"
good; echo inactive > "$W/t"; run FAKE_TIMER=inactive;                       ds_expect UPL-02 FAIL "ladder timer not active"
good; printf '{"rung":"eth0","verdict":"full","strikes":0,"parked":"","updated_at":"x"}\n' > "$W/status.json"; run
ds_expect UPL-04 FAIL "old schema without spare/last_rung/searching/last_rescan"
good; printf '{"rung":"eth0","verdict":"full","strikes":0,"parked":"","spare":"","last_rung":"false","searching":false,"last_rescan":"","updated_at":"%s"}\n' "$(iso $((NOW - 30)))" > "$W/status.json"; run
ds_expect UPL-04b FAIL "last_rung is a string"
good; status full 0 false false "" 900; run;                                  ds_expect UPL-04c FAIL "status 900 s old: the timer is not firing"
good; status full 0 false true "" 30; run;                                   ds_expect UPL-05 FAIL "healthy but searching"
good; status full 0 true false "" 30; run;                                   ds_expect UPL-05 FAIL "healthy but 'last rung'"
good; status full 0 false false "$(iso $((NOW - 120)))" 30; run;             ds_expect UPL-05 FAIL "healthy but rescanned 2 min ago"
good; printf '%s\n' "ga-uplink-ladder: no spare uplink in the scan cache - forcing a Wi-Fi rescan (8s)" > "$W/journal"; run FAKE_JOURNAL="$W/journal"
ds_expect UPL-05 FAIL "rescan line in the journal on a healthy device"
good; status none 3 true true "$(iso $((NOW - 60)))" 30; run;                 ds_expect UPL-05 SKIP "offline device: the bench scenario, never a pass"
good; printf 'GA-1234\t1\t%s\n' $((NOW + 1800)) > "$W/backoff"; run;          ds_expect UPL-11 PASS "a valid back-off entry"
good; printf 'GA-1234\t0\t%s\n' $((NOW + 1800)) > "$W/backoff"; run;          ds_expect UPL-11 FAIL "level 0"
good; printf 'GA-1234\t1\t%s\n' $((NOW + 900000)) > "$W/backoff"; run;        ds_expect UPL-11 FAIL "bar years ahead (clock jump)"
good; printf 'garbage\n' > "$W/backoff"; run;                                  ds_expect UPL-11 FAIL "garbage back-off file"
good; { cat "$OSC"; echo 'curl -s http://example.invalid/ >/dev/null'; } > "$W/osc-curl"; run GA_UPLD_OSC="$W/osc-curl"
ds_expect UPL-13 FAIL "auto-connect with a private curl"
good; grep -v 'networking connectivity check' "$OSC" > "$W/osc-nonm"; run GA_UPLD_OSC="$W/osc-nonm"
ds_expect UPL-12 FAIL "auto-connect without the NM probe"

ds_done
