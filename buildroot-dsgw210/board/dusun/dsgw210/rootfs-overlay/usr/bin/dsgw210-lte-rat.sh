#!/bin/sh
# DSGW-210 LTE — READ the Quectel BG96's radio-access configuration, never write it.
#
# Decision 2026-11-19 (Odoo #2187, option A): the modem's non-volatile RAT/band
# configuration stays as the manufacturer shipped it. The modem chooses LTE-M,
# NB-IoT or 2G itself. Until BOSv1.6.0-dev16 this script wrote
# nwscanmode=3 / iotopmode=0 into the NVM on every boot; that changed the
# certified configuration and, once, raced ModemManager's probe of the same AT
# port (the modem was marked invalid for the whole boot).
#
# Now: read nwscanmode, nwscanseq, iotopmode, band and the firmware revision,
# log them and leave them in $STATUS (JSON) so a deviation from the stock values
# can be seen per device. A unit whose NVM an older image already rewrote keeps
# those values until someone restores them deliberately — that is logged, not
# fixed here. Only QUERY forms are sent (AT+QCFG="name" without a value);
# tests/ga_tests/lte_rat must-fail on any set form.
#
# Runs Before=ModemManager.service so the AT port is still free. Always exits 0:
# LTE is a fallback link and must never delay or block the boot.

AT=${GA_LTE_AT:-/dev/lte-at}
STATUS=${GA_LTE_RAT_STATUS:-/run/dsgw210-lte-rat.json}
OUT=${GA_LTE_RAT_TMP:-/tmp/lte-rat.out}
REPLY_S=${GA_LTE_RAT_REPLY_S:-3}
log() { echo "dsgw210-lte-rat: $*"; }

# q CMD — send one QUERY, leave the reply in $OUT; 0 only if the modem said OK.
q() {
	( timeout "$REPLY_S" cat "$AT" > "$OUT" 2>/dev/null & )
	sleep 0.3
	printf '%s\r' "$1" > "$AT" 2>/dev/null || return 1
	sleep "$REPLY_S"
	grep -q 'OK' "$OUT" 2>/dev/null
}
# val NAME — the value list of +QCFG: "NAME",<values> from the last reply.
val() { sed -n "s/^+QCFG: \"$1\",\([^[:cntrl:]]*\).*/\1/p" "$OUT" | head -1 | tr -d ' "'; }

w=0
while [ ! -e "$AT" ]; do
	w=$((w + 1))
	if [ "$w" -gt 30 ]; then log "$AT absent after ~60 s — nothing read"; exit 0; fi
	sleep 2
done
stty -F "$AT" 115200 raw -echo 2>/dev/null || true

w=0
until q 'AT'; do
	w=$((w + 1))
	if [ "$w" -gt 20 ]; then log "modem not answering AT — nothing read"; exit 0; fi
	sleep 1
done

json="{"
for k in nwscanmode nwscanseq iotopmode band; do
	if q "AT+QCFG=\"$k\""; then v=$(val "$k"); else v=""; fi
	log "$k=${v:-<no answer>}"
	json="$json\"$k\":\"$v\","
done
if q 'AT+QGMR'; then fw=$(grep -v -e '^AT' -e '^OK' -e '^[[:space:]]*$' "$OUT" | head -1 | tr -d '\r '); else fw=""; fi
log "firmware=${fw:-<no answer>}"
printf '%s"firmware":"%s","written":false,"ts":%s}\n' "$json" "$fw" "$(date +%s)" > "$STATUS" 2>/dev/null || true
rm -f "$OUT"
exit 0
