#!/bin/sh
# On-device check for the DSGW USB port allowlist (Odoo #2189). Run on the device as root.
#   BCD-00  every allowlist entry is <controller>:<chain>, no bus-number key (an image before the
#           fix FAILs here: its 3-1 entries break on a boot where the hub lands on another bus)
#   BCD-01  the on-board hub and every device behind it are authorized, whatever bus number
#           the EHCI got this boot (it moves between boots: usb3 on one, usb4 on the next)
#   BCD-02  the three internal devices enumerate: the modem (2c7c:*) and two serial radios (1a86:7523)
# Boards without /usr/share/ga-usb-port-allowlist (the iHost): SKIP.
# GA_BCD_CTRL=<controller> runs BCD-01/02 against that controller even when BCD-00 fails.
set -u
PORTS=/usr/share/ga-usb-port-allowlist
if [ ! -f "$PORTS" ]; then echo "  SKIP  BCD-01/02: no port allowlist on this board"; exit 0; fi
rc=0
bad=$(grep -vE '^[[:space:]]*(#|$)' "$PORTS" | grep -vE '^[A-Za-z0-9._-]+\.usb:[0-9]+(\.[0-9]+)*$' | tr '\n' ' ')
if [ -z "$bad" ]; then echo "  PASS  BCD-00: allowlist entries are controller:chain"
else echo "  FAIL  BCD-00: allowlist has bus-number/unknown entries: $bad(Odoo #2189)"; rc=1; fi
CTRL=${GA_BCD_CTRL:-$(grep -vE '^[[:space:]]*(#|$)' "$PORTS" | grep -E '^[A-Za-z0-9._-]+\.usb:' | head -1 | cut -d: -f1)}
ROOT=""; [ -n "$CTRL" ] && ROOT=$(find /sys/devices/platform/"$CTRL"/ -maxdepth 1 -name "usb[0-9]*" 2>/dev/null | head -1)
if [ -z "$ROOT" ]; then echo "  FAIL  BCD-01/02: no USB bus under controller '${CTRL:-none}'"; exit 1; fi
BUS=${ROOT##*/usb}
denied=""; n=0
# the hub and everything behind it: 4-1, 4-1/4-1.1 ... (interfaces 4-1:1.0 are not devices)
DEVS=$(find "$ROOT"/ -maxdepth 4 -type d -name "$BUS-*" 2>/dev/null | grep -v ':' | sort)
for d in $DEVS; do
  [ -f "$d/authorized" ] || continue
  n=$((n + 1))
  [ "$(cat "$d/authorized")" = 1 ] || denied="$denied ${d##*/}"
done
if [ "$n" -gt 0 ] && [ -z "$denied" ]; then
  echo "  PASS  BCD-01: $n device(s) under $CTRL authorized (bus $BUS this boot)"
else
  echo "  FAIL  BCD-01: under $CTRL (bus $BUS): $n device(s), unauthorized:${denied:- none}"; rc=1
fi
# only AUTHORIZED devices count: an unauthorized one still shows its IDs in sysfs
ids=$(for d in $DEVS; do [ -f "$d/idVendor" ] && [ "$(cat "$d/authorized" 2>/dev/null)" = 1 ] && echo "$(cat "$d/idVendor"):$(cat "$d/idProduct")"; done | sort | tr '\n' ' ')
modem=$(echo "$ids" | tr ' ' '\n' | grep -c '^2c7c:')
radios=$(echo "$ids" | tr ' ' '\n' | grep -c '^1a86:7523$')
if [ "$modem" -ge 1 ] && [ "$radios" -eq 2 ]; then
  echo "  PASS  BCD-02: modem + 2 serial radios authorized under the controller ($ids)"
else
  echo "  FAIL  BCD-02: behind the hub: '${ids}' (want 2c7c:* and 2x 1a86:7523)"; rc=1
fi
exit $rc
