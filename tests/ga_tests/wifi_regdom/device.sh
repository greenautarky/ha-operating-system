#!/bin/sh
# On-device check for ga-wifi-regdom (Odoo #2183). Run on the device as root.
#   WRD-01  the unit ran and succeeded this boot
#   WRD-02  the kernel's global regulatory domain is the configured country
#           (SKIP with the reason when an access point in range forces the "98" intersection)
set -u
. /usr/share/ga-board.conf 2>/dev/null
WANT=$(sed -n '1{s/[[:space:]]//g;p;q}' /mnt/boot/ga-wifi-country 2>/dev/null)
printf '%s' "$WANT" | grep -Eq '^[A-Z]{2}$' || WANT="${GA_WIFI_COUNTRY:-}"
if [ -z "$WANT" ]; then echo "  SKIP  WRD-01/02: no Wi-Fi country configured on this board"; exit 0; fi
rc=0
R=$(systemctl show ga-wifi-regdom.service -p Result --value 2>/dev/null); A=$(systemctl show ga-wifi-regdom.service -p ActiveState --value 2>/dev/null)
if [ "$R" = success ] && [ "$A" = active ]; then echo "  PASS  WRD-01: ga-wifi-regdom ran this boot (Result=success)"; else echo "  FAIL  WRD-01: ga-wifi-regdom Result='$R' ActiveState='$A'"; rc=1; fi
GOT=$(iw reg get 2>/dev/null | sed -n '/^global/,/^$/{s/^country \([A-Z0-9][A-Z0-9]\):.*/\1/p}' | head -1)
case "$GOT" in
  "$WANT") echo "  PASS  WRD-02: global regulatory domain = $WANT" ;;
  98) echo "  SKIP  WRD-02: kernel shows the intersection 98 - an access point in range advertises another country (configured: $WANT)" ;;
  *) echo "  FAIL  WRD-02: global regulatory domain '${GOT:-none}', configured $WANT"; rc=1 ;;
esac
exit $rc
