#!/bin/sh
# dns_config selftest — what DNS-12/13 expect (expected_ip.sh), host side.
#
# Drives the LIVE functions test.sh sources with fixture config files
# (fixtures/, documentation addresses only):
#   must-pass  an override WITHOUT GA_SERVICES_IP → the baked value (the
#              BOSv1.5.0-rc1 false FAIL); no override; an override that sets
#              the key; the OTA name from the active pick, else GA_OTA_IPS
#   must-fail  no value anywhere; an override that blanks the key; a value that
#              is not an address — each with a reason, never a guessed address
# and that test.sh uses them and carries no hardcoded address for DNS-12/13.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
. "$HERE/../lib/test_helpers.sh"
. "$HERE/expected_ip.sh"
suite_start "dns_config DNS-12/13 expectation (host)"
FX="$HERE/fixtures"
NONE="$FX/does-not-exist.conf"
for f in baked baked-no-key override-no-key override-with-key override-empty-key override-not-ip; do
	[ -f "$FX/$f.conf" ] || { echo "FATAL: fixture $f.conf missing — refusing to pass over nothing"; exit 1; }
done

# A value from the caller's environment must never stand in for the file's.
export GA_SERVICES_IP=203.0.113.99 GA_OTA_IPS=203.0.113.98

# svc <baked> <override> / ota <baked> <override> <active> — print "<rc>|<out>"
svc() { o="$(ga_expected_services_ip "$1" "$2")"; printf '%s|%s' "$?" "$o"; }
ota() { o="$(ga_expected_ota_ip "$1" "$2" "$3")"; printf '%s|%s' "$?" "$o"; }

V="$(svc "$FX/baked.conf" "$FX/override-no-key.conf")"
run_test_show "DNSV-01" "override present WITHOUT the key → the baked value" \
	'echo "$V"; [ "$V" = "0|192.0.2.10" ]'
V="$(svc "$FX/baked.conf" "$NONE")"
run_test_show "DNSV-02" "no override → the baked value" 'echo "$V"; [ "$V" = "0|192.0.2.10" ]'
V="$(svc "$FX/baked.conf" "$FX/override-with-key.conf")"
run_test_show "DNSV-03" "override sets the key → the override's value" 'echo "$V"; [ "$V" = "0|198.51.100.20" ]'
V="$(svc "$FX/baked-no-key.conf" "$FX/override-no-key.conf")"
run_test_show "DNSV-04" "the key set nowhere → FAIL with a reason, no fallback address" \
	'echo "$V"; [ "${V%%|*}" = 1 ] && echo "$V" | grep -q "GA_SERVICES_IP is unset or empty"'
V="$(svc "$FX/baked.conf" "$FX/override-empty-key.conf")"
run_test_show "DNSV-05" "override blanks the key → FAIL with a reason (as ga-update-hosts refuses it)" \
	'echo "$V"; [ "${V%%|*}" = 1 ]'
V="$(svc "$FX/baked.conf" "$FX/override-not-ip.conf")"
run_test_show "DNSV-06" "a value that is not an IPv4 address → FAIL with a reason" \
	'echo "$V"; [ "${V%%|*}" = 1 ] && echo "$V" | grep -q "not an IPv4"'

V="$(ota "$FX/baked.conf" "$FX/override-no-key.conf" "$FX/ota-active.txt")"
run_test_show "DNSV-10" "ota: the active pick wins" 'echo "$V"; [ "$V" = "0|198.51.100.7" ]'
V="$(ota "$FX/baked.conf" "$FX/override-no-key.conf" "$NONE")"
run_test_show "DNSV-11" "ota: no active pick → the first GA_OTA_IPS entry" 'echo "$V"; [ "$V" = "0|192.0.2.10" ]'
V="$(ota "$FX/baked-no-key.conf" "$NONE" "$NONE")"
run_test_show "DNSV-12" "ota: nothing configured → FAIL with a reason" 'echo "$V"; [ "${V%%|*}" = 1 ]'

# The seam: the real baked conf in this tree, read by the function, under the
# measured override shape. The expected value is read with a different method
# (sed of the assignment), not by sourcing.
REAL="$REPO/buildroot-external/rootfs-overlay/etc/ga-services.conf"
RAW="$(sed -n 's/^GA_SERVICES_IP=//p' "$REAL" | tr -d '"')"
V="$(svc "$REAL" "$FX/override-no-key.conf")"
run_test_show "DNSV-20" "the repo's baked conf + an override without the key → its own GA_SERVICES_IP" \
	'echo "$V"; [ -n "$RAW" ] && [ "$V" = "0|$RAW" ]'

T="$HERE/test.sh"
run_test "DNSV-30" "test.sh takes DNS-12/13's expectation from expected_ip.sh" \
	"grep -q 'ga_expected_ota_ip \"\$CONF_BAKED\"' '$T' && grep -q 'ga_expected_services_ip \"\$CONF_BAKED\"' '$T'"
# Allowed: the CoreDNS address and the public resolvers DNS-04/06/07 check.
no_ip_literal() {
	[ -z "$(grep -nE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' "$1" \
		| grep -vE 'COREDNS_HOST=|1\.1\.1\.1|1\.0\.0\.1')" ]
}
run_test "DNSV-31" "test.sh carries no hardcoded GA address" "no_ip_literal '$T'"

suite_end
