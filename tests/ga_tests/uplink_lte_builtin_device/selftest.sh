#!/bin/sh
# Host-side selftest of uplink_lte_builtin_device/test.sh: the LIVE suite against stubs of
# systemctl / mmcli / nmcli / ip / nft / systemd-run only. Must-PASS: a DSGW with a registered
# modem (non-destructive rows, and the destructive failover when the flag is set). Must-FAIL: every
# broken state on the NAMED row. Must-SKIP: no SIM, iHost, destructive without the flag, no firewall
# table. A row that cannot go red, or cannot go green, is not evidence (working-method rules 6, 45).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/devsuite_selftest.sh"
ds_init
NOW=1800000000

cat > "$W/bin/systemctl" <<'STUB'
#!/bin/sh
case "$*" in is-active*) echo "${FAKE_MM:-active}" ;; esac
exit 0
STUB
cat > "$W/bin/systemd-run" <<'STUB'
#!/bin/sh
echo "systemd-run $*" >> "$W_LOG"
STUB
cat > "$W/bin/mmcli" <<'STUB'
#!/bin/sh
[ "${FAKE_NOMODEM:-0}" = 1 ] && { echo "error: no modems were found"; exit 0; }
echo "    /org/freedesktop/ModemManager1/Modem/0 [Quectel] BG96"
STUB
cat > "$W/bin/nmcli" <<'STUB'
#!/bin/sh
case "$*" in
  "-g connection.type connection show "*) echo "${FAKE_NM_TYPE:-gsm}" ;;
  "-g gsm.apn connection show "*)         echo "${FAKE_APN:-}" ;;
  "-t -f DEVICE,TYPE device")             printf 'end0:ethernet\nttyUSB2:gsm\nlo:loopback\n' ;;
  "-g GENERAL.IP-IFACE device show "*)    echo lo ;;
  "-t -f NAME,DEVICE connection show --active") printf 'Wired connection 1:end0\n' ;;
  "device disconnect end0")  [ "${FAKE_NOFAILOVER:-0}" = 1 ] || echo lo > "$W_ROUTE" ;;
  "device connect end0")     [ "${FAKE_NOBACK:-0}" = 1 ] || echo end0 > "$W_ROUTE" ;;
  "networking connectivity check") echo "${FAKE_CONN:-full}" ;;
esac
exit 0
STUB
cat > "$W/bin/ip" <<'STUB'
#!/bin/sh
echo "default dev $(cat "$W_ROUTE") scope link"
STUB
cat > "$W/bin/nft" <<'STUB'
#!/bin/sh
[ -s "${FAKE_NFT:-/nonexistent}" ] && cat "$FAKE_NFT"
exit 0
STUB
chmod +x "$W/bin/"*

good_status() {
  cat > "$W/status.json" <<EOF
{"rung":"Wired connection 1","verdict":"full","strikes":0,"parked":"","spare":"","last_rung":false,"searching":false,"last_rescan":"","updated_at":"x","modem":{"present":true,"registered":true,"bearer_up":true,"iface":"lo","state":"connected","failed_reason":"","operator":"TestNet","tech":"lte","signal":64}}
EOF
}
good_nft() {
  cat > "$W/nft.out" <<'EOF'
table inet ga_firewall {
  chain input {
    type filter hook input priority 0; policy accept;
    iif "lo" accept
    iifname { "end0", "wlan0" } tcp dport { 22222, 80, 8123 } accept
    iifname { "end0", "wlan0" } drop
    drop
  }
  chain forward {
    type filter hook forward priority -5; policy accept;
    ct status dnat drop
  }
}
EOF
}
good() { good_status; good_nft; echo end0 > "$W/route"; }
run() { ds_run uplink_lte_builtin_device W_LOG="$W/log" W_ROUTE="$W/route" GA_ULB_STATUS="$W/status.json" \
  GA_ULB_IP="$W/bin/ip" GA_ULB_BOARD="${BOARD:-dsgw210}" GA_ULB_BOUND_S=1 GA_ULB_BACK_S=1 FAKE_NFT="$W/nft.out" "$@"; }
chg() { jq "$1" "$W/status.json" > "$W/s2" && mv "$W/s2" "$W/status.json"; }

echo "== known-good DSGW, registered modem: every non-destructive row PASS, destructive rows SKIP"
good; run
for i in ULB-01 ULB-02 ULB-03 ULB-04 ULB-05 ULB-06 ULB-07 ULB-08; do ds_expect "$i" PASS "healthy DSGW with a registered modem"; done
ds_expect "ULB-20..24" SKIP "no GA_TEST_DESTRUCTIVE"

echo "== known-good DSGW, destructive: Ethernet away -> LTE -> back"
good; run GA_TEST_DESTRUCTIVE=1
for i in ULB-20 ULB-21 ULB-22 ULB-23 ULB-24; do ds_expect "$i" PASS "failover chain works"; done
grep -q "systemd-run.*ulb-restore-eth" "$W/log" && { DS_PASS=$((DS_PASS+1)); echo "  ok    failsafe timer armed BEFORE the cut"; } || { DS_FAIL=$((DS_FAIL+1)); echo "  FAIL  failsafe timer not armed"; }

echo "== iHost: every row SKIPs with the reason"
good; BOARD=ihost; run
for i in ULB-01 ULB-04 ULB-08 ULB-20; do ds_expect "$i" SKIP "iHost has no built-in modem"; done
BOARD=dsgw210

echo "== must-skip: no SIM, no firewall table"
good; chg '.modem.registered=false | .modem.bearer_up=false | .modem.state="failed" | .modem.failed_reason="sim-missing"'; run
ds_expect ULB-06 SKIP "SIM missing is a bench step, never a pass"; ds_expect ULB-07 SKIP "no registration, no bearer row"
good; chg '.modem.registered=false | .modem.bearer_up=false | .modem.state="failed" | .modem.failed_reason="sim-missing"'; run GA_TEST_DESTRUCTIVE=1
ds_expect ULB-20 SKIP "destructive half needs a registered modem"
good; : > "$W/nft.out"; run;                                   ds_expect ULB-08 SKIP "firewall table not loaded"

echo "== must-flag"
good; run FAKE_MM=inactive;                                    ds_expect ULB-01 FAIL "ModemManager not active"
good; run FAKE_NOMODEM=1;                                      ds_expect ULB-02 FAIL "no modem enumerated"
good; run FAKE_NM_TYPE=ethernet;                               ds_expect ULB-03 FAIL "profile missing / wrong type"
good; run FAKE_APN=internet.telekom;                           ds_expect ULB-03 FAIL "a carrier APN pinned in the image"
good; chg 'del(.modem)'; run;                                  ds_expect ULB-04 FAIL "status without the modem object (ga_manager has nothing to read)"
good; chg '.modem.registered="yes"'; run;                      ds_expect ULB-04 FAIL "registered is a string"
good; chg 'del(.modem.failed_reason)'; run;                    ds_expect ULB-04 FAIL "a key missing"
good; chg '.modem.present=false'; run;                         ds_expect ULB-05 FAIL "modem not present"
good; chg '.modem.registered=false | .modem.state="searching"'; run; ds_expect ULB-06 FAIL "SIM there, not registered"
good; chg '.modem.bearer_up=false'; run;                       ds_expect ULB-07 FAIL "registered but no bearer"
good; chg '.modem.iface="nosuch9"'; run;                       ds_expect ULB-07 FAIL "iface the kernel does not have"
good; sed -i 's/iifname { "end0", "wlan0" } tcp/iifname { "end0", "wlan0", "lo" } tcp/' "$W/nft.out"; run
ds_expect ULB-08 FAIL "the modem interface in a service accept rule"
good; grep -vx '    drop' "$W/nft.out" > "$W/n2"; mv "$W/n2" "$W/nft.out"; run;  ds_expect ULB-08 FAIL "input chain without a final drop"
good; run GA_TEST_DESTRUCTIVE=1 FAKE_NOFAILOVER=1;             ds_expect ULB-20 FAIL "default route never moves to the modem"
good; run GA_TEST_DESTRUCTIVE=1 FAKE_CONN=limited;             ds_expect ULB-21 FAIL "no internet over LTE"
good; run GA_TEST_DESTRUCTIVE=1 FAKE_NOBACK=1;                 ds_expect ULB-23 FAIL "never returns to Ethernet"
good; run GA_TEST_DESTRUCTIVE=1 FAKE_NOBACK=1 FAKE_CONN=none;  ds_expect ULB-24 FAIL "no internet after the return"

ds_done
