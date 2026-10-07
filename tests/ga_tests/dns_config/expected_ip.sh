#!/bin/sh
# expected_ip.sh — the addresses DNS-12/13 expect, kept free of device access
# so selftest.sh can drive them with fixture config files in CI.
#
# The expectation follows the precedence the writers of those names use
# (ga-update-hosts for /etc/hosts, the Supervisor's DNS plugin for CoreDNS):
# the baked /etc/ga-services.conf, with the /mnt/data override layered on top
# PER KEY. An override file that does not set a key leaves the baked value in
# force. There is no hardcoded fallback: a value that cannot be read is a
# failure with a reason, never a guessed address.
#
# The pre-fix code took GA_SERVICES_IP from the override whenever the file
# existed, got "" from an override that only sets other keys, and then fell
# back to a constant address the services had already moved away from — so a
# correctly configured device failed DNS-12 and DNS-13.

# ga_conf_value <KEY> <baked-file> <override-file> — the key's effective value
# (empty when neither file sets it). Sourced in a subshell with the key unset
# first, so nothing from the caller's environment can stand in for it.
ga_conf_value() {
	case "$1" in ''|*[!A-Z0-9_]*) return 1 ;; esac
	(
		_gcv_key="$1"; _gcv_baked="$2"; _gcv_over="$3"
		unset "$_gcv_key"
		[ -f "$_gcv_baked" ] && . "$_gcv_baked" >/dev/null 2>&1
		[ -f "$_gcv_over" ] && . "$_gcv_over" >/dev/null 2>&1
		eval "printf '%s' \"\${$_gcv_key:-}\""
	)
}

_is_ipv4() {
	printf '%s' "$1" | grep -qxE '([0-9]{1,3}\.){3}[0-9]{1,3}'
}

# ga_expected_services_ip <baked-file> <override-file>
#   0: prints the effective GA_SERVICES_IP
#   1: prints why there is none (unset, or not an IPv4 address)
ga_expected_services_ip() {
	_ip="$(ga_conf_value GA_SERVICES_IP "$1" "$2")"
	if [ -z "$_ip" ]; then
		echo "GA_SERVICES_IP is unset or empty after reading $1, then $2"; return 1
	fi
	_is_ipv4 "$_ip" || { echo "GA_SERVICES_IP is not an IPv4 address: $_ip"; return 1; }
	echo "$_ip"
}

# ga_expected_ota_ip <baked-file> <override-file> <active-pick-file>
#   The OTA name follows ga-update-hosts: the active pick of ga-resolve-ota,
#   else the first GA_OTA_IPS entry, else GA_SERVICES_IP.
ga_expected_ota_ip() {
	_ip=""
	[ -f "$3" ] && _ip="$(tr -d '[:space:]' < "$3")"
	[ -n "$_ip" ] || _ip="$(ga_conf_value GA_OTA_IPS "$1" "$2" | awk '{ print $1 }')"
	[ -n "$_ip" ] || { ga_expected_services_ip "$1" "$2"; return $?; }
	_is_ipv4 "$_ip" || { echo "the OTA address is not an IPv4 address: $_ip"; return 1; }
	echo "$_ip"
}
