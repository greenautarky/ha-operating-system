#!/bin/sh
# wifi_scan.sh — OS-04's verdict, kept free of device access so selftest.sh can
# drive it with fixtures in CI. test.sh measures; this judges.
#
# wifi_scan_verdict < `nmcli -t -f BSSID,SSID dev wifi list`
#   Prints one line (the reason). 0 = the scan returned at least one BSS,
#   1 = it returned none.
#
# The question is "did the scan complete", so ANY row passes. A hidden network
# is a row with a BSSID and an empty SSID. The pre-fix check took `head -1` of
# the SSID column alone, and the strongest BSS sorts first — so a scan that
# found ten networks was a FAIL whenever the strongest of them was hidden.
# Whether a GA-* SSID is among them is OS-05's question, not this one.
wifi_scan_verdict() {
	awk '
		NF == 0 { next }
		{ n++ }
		# terse mode escapes the colons inside the BSSID as "\:", so the SSID
		# is empty when the line ends in an unescaped ":"
		/[^\\]:$/ { hidden++ }
		END {
			if (n == 0) { print "the scan returned no networks (empty nmcli wifi list)"; exit 1 }
			printf "%d network(s) in the scan, %d of them hidden\n", n, hidden
		}'
}
