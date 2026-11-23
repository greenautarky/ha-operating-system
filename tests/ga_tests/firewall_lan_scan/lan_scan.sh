#!/bin/sh
# lan_scan.sh <device-ip> <board> — live LAN-side firewall proof (KB #363, Odoo #1652/#2193).
# Run from a host in the device's LAN (not on the device). Read-only TCP connect scan.
set -u
D="$(cd "$(dirname "$0")" && pwd)"; T="$(mktemp)"; trap 'rm -f "$T"' EXIT
command -v nmap >/dev/null || { echo "UNUSABLE: nmap not installed on this host"; exit 2; }
nmap -sT -Pn -p- --min-rate 2000 -T4 -oG - "$1" 2>/dev/null | sed "s/$1/DEVICE/" > "$T"
echo "scan of $1 (board $2) at $(date -u +%FT%TZ):"; sh "$D/lan_scan_check.sh" "$2" "$T"
