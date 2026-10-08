#!/bin/sh
# openstick selftest — OS-04's verdict (wifi_scan.sh), host side, no device.
#
# Drives the LIVE wifi_scan_verdict that test.sh sources with nmcli-shaped
# fixtures (fixtures/scan-*.txt, `nmcli -t -f BSSID,SSID dev wifi list`):
#   must-pass  a hidden network (empty SSID) as the FIRST row — the BOSv1.5.0-rc1
#              false FAIL; only hidden networks; named networks, one with an
#              apostrophe in its SSID
#   must-fail  an empty scan; a scan of blank lines
# and that test.sh judges OS-04 through it.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/test_helpers.sh"
. "$HERE/wifi_scan.sh"
suite_start "openstick OS-04 scan verdict (host)"
FX="$HERE/fixtures"

# verdict <fixture> — prints "<rc>|<reason>"
verdict() { m="$(wifi_scan_verdict < "$1")"; printf '%s|%s' "$?" "$m"; }

for f in scan-hidden-first scan-only-hidden scan-named scan-empty scan-blank-lines; do
	[ -f "$FX/$f.txt" ] || { echo "FATAL: fixture $f.txt missing — refusing to pass over nothing"; exit 1; }
done
# The must-pass fixture is only evidence if its first row really is hidden.
run_test "OSV-00" "fixture: the first row of scan-hidden-first is a hidden network" \
	"head -n1 '$FX/scan-hidden-first.txt' | grep -q '[^\\\\]:\$'"

V="$(verdict "$FX/scan-hidden-first.txt")"
run_test_show "OSV-01" "hidden network first → pass, all 3 rows counted" \
	'echo "$V"; [ "$V" = "0|3 network(s) in the scan, 1 of them hidden" ]'
V="$(verdict "$FX/scan-only-hidden.txt")"
run_test_show "OSV-02" "only a hidden network → pass (the scan completed)" \
	'echo "$V"; [ "$V" = "0|1 network(s) in the scan, 1 of them hidden" ]'
V="$(verdict "$FX/scan-named.txt")"
run_test_show "OSV-03" "named networks, one SSID with an apostrophe → pass" \
	'echo "$V"; [ "$V" = "0|2 network(s) in the scan, 0 of them hidden" ]'
V="$(verdict "$FX/scan-empty.txt")"
run_test_show "OSV-04" "empty scan → FAIL with a reason" \
	'echo "$V"; [ "$V" = "1|the scan returned no networks (empty nmcli wifi list)" ]'
V="$(verdict "$FX/scan-blank-lines.txt")"
run_test_show "OSV-05" "blank lines only → FAIL, not counted as networks" \
	'echo "$V"; [ "${V%%|*}" = 1 ]'

T="$HERE/test.sh"
run_test "OSV-06" "test.sh judges OS-04 with wifi_scan_verdict over BSSID,SSID rows" \
	"grep -q 'nmcli -t -f BSSID,SSID dev wifi list 2>/dev/null | wifi_scan_verdict' '$T' && grep -q 'show_verdict \"OS-04\"' '$T'"
run_test "OSV-07" "test.sh no longer judges the scan by its first row" \
	"! grep -n 'wifi list.*head -1' '$T'"

suite_end
