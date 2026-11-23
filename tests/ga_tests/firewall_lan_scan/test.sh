#!/bin/sh
# firewall_lan_scan — the LAN-side nmap judgement against pinned per-board lists (Odoo #2193).
# Fixtures: must-pass = a real scan of a DSGW (DUT2, dev16); must-fail = the same with one change each.
set -u
D="$(cd "$(dirname "$0")" && pwd)"; C="$D/lan_scan_check.sh"; pass=0; fail=0
t() { # id expected_rc fixture want_line
  out=$(sh "$C" dsgw210 "$D/fixtures/$3" 2>&1); rc=$?
  if [ "$rc" = "$2" ] && echo "$out" | grep -q "$4"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1 (rc=$rc: $(echo "$out" | tr '\n' ' '))"; fail=$((fail+1)); fi
}
echo ""; echo "=== firewall_lan_scan: LAN-side open ports vs pinned list ==="
t "FLS-01 real DSGW scan (dev16) passes: 80+22222 open, rest filtered, full range" 0 must-pass-dsgw210-dev16.gnmap "PASS LSC-03"
t "FLS-02 an extra open port (1883) fails LSC-01" 1 must-fail-extra-open-port.gnmap "FAIL LSC-01 open TCP .80 1883 22222."
t "FLS-03 reject instead of drop fails LSC-02" 1 must-fail-reject-not-drop.gnmap "FAIL LSC-02"
t "FLS-04 a partial scan fails LSC-03" 1 must-fail-partial-scan.gnmap "FAIL LSC-03"
t "FLS-05 an empty scan (host down) is UNUSABLE, never a pass" 2 must-fail-empty.gnmap "UNUSABLE"
out=$(sh "$C" nosuchboard "$D/fixtures/must-pass-dsgw210-dev16.gnmap"); [ $? = 2 ] && { echo "  PASS  FLS-06 unknown board is UNUSABLE"; pass=$((pass+1)); } || { echo "  FAIL  FLS-06"; fail=$((fail+1)); }
echo ""; echo "firewall_lan_scan: $pass passed, $fail failed"
echo "{\"suite\":\"firewall_lan_scan\",\"pass\":$pass,\"fail\":$fail,\"skip\":0}"
[ "$fail" -eq 0 ] && [ "$pass" -eq 6 ]
