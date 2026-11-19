#!/bin/sh
# On-device check for the DSGW BLE scanner bridge ga_dsgw_ble (Odoo #2187). Run on the device as root.
#   DBL-01  the NCP's port exists (hub port 1.2 by-path)
#   DBL-02  ga_dsgw_ble's status is fresh (< 120 s) and says scanning
#   DBL-03  advertisements arrive: reports in the last 60 s > 0 and the last one < 60 s old
#   DBL-04  HA's bluetooth manager holds addresses from this scanner (the seam, not the bridge's own count)
#   DBL-05  nothing else holds the NCP's port open but Core (no hciattach/bul from an old setup)
# Boards without the NCP port (the iHost): SKIP.
set -u
PORT=/dev/serial/by-path/platform-ff5c0000.usb-usb-0:1.2:1.0-port0
ST=${GA_DBL_STATUS:-/mnt/data/supervisor/homeassistant/.ga_dsgw_ble_status.json}
if [ ! -e "$PORT" ]; then echo "  SKIP  DBL-01..05: no DSGW BLE NCP port on this board"; exit 0; fi
echo "  PASS  DBL-01: NCP port present ($(readlink -f "$PORT"))"
rc=0
if [ ! -s "$ST" ]; then echo "  FAIL  DBL-02: no status file $ST (integration not loaded?)"; exit 1; fi
j() { jq -r "$1" "$ST" 2>/dev/null; }
now=$(date +%s); ts=$(j '.ts | floor'); state=$(j .state)
age=$((now - ${ts:-0}))
if [ "$state" = scanning ] && [ "$age" -lt 120 ]; then echo "  PASS  DBL-02: state scanning, status ${age}s old (sessions $(j .sessions))"
else echo "  FAIL  DBL-02: state '$state', status ${age}s old, last_error '$(j .last_error)'"; rc=1; fi
r60=$(j .reports_60s); last=$(j '.last_report_age_s // 9999 | floor')
if [ "${r60:-0}" -gt 0 ] && [ "${last:-9999}" -lt 60 ]; then echo "  PASS  DBL-03: $r60 reports in 60 s, last ${last}s ago"
else echo "  FAIL  DBL-03: reports_60s=$r60 last_report_age_s=$last"; rc=1; fi
ha=$(j .ha_discovered_addresses)
if [ "${ha:-0}" -gt 0 ]; then echo "  PASS  DBL-04: HA bluetooth manager holds $ha address(es) from ga-dsgw-ble"
else echo "  FAIL  DBL-04: HA holds no address from ga-dsgw-ble"; rc=1; fi
dev=$(readlink -f "$PORT"); holders=""
for p in /proc/[0-9]*; do
  for fd in "$p"/fd/*; do [ "$(readlink "$fd" 2>/dev/null)" = "$dev" ] && holders="$holders $(cat "$p/comm")"; done
done
case "$holders" in
  *hciattach*|*bul*|*btattach*) echo "  FAIL  DBL-05: port also held by:$holders"; rc=1 ;;
  *python*) echo "  PASS  DBL-05: port held by Core only ($(echo $holders | tr ' ' '\n' | sort -u | tr '\n' ' '))" ;;
  *) echo "  FAIL  DBL-05: port not held by Core (holders:${holders:- none})"; rc=1 ;;
esac
exit $rc
