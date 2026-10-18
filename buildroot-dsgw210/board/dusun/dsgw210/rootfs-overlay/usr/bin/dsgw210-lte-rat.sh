#!/bin/sh
# DSGW-210 LTE — pin the Quectel BG96 to Cat-M1 / LTE-M.
#
# ModemManager + NetworkManager own the LTE connection (a `gsm` profile);
# this one-shot only forces the radio-access technology, which is a
# Quectel-proprietary QCFG knob ModemManager does not expose:
#   nwscanmode=3  -> LTE only (no 2G/EGPRS fallback)
#   iotopmode=0   -> Cat-M1 (LTE-M), not NB-IoT
# The trailing ",1" saves both to the modem's non-volatile memory, so on
# any subsequent boot the modem already comes up as Cat-M1 — re-asserting
# here every boot is just idempotent insurance for a virgin/swapped modem.
#
# Runs Before=ModemManager.service so the AT port is still free; MM grabs
# it exclusively once it probes the modem. Always exits 0 — LTE is a
# fallback link and must never delay or block the boot.
#
# NB: ModemManager's BG96 support models only one mode combo (2g/3g/4g)
# and mis-labels a Cat-M1 link as "access tech: gsm" in `mmcli` — that is
# cosmetic. The real RAT is what this script sets; confirm with
# `AT+QNWINFO` / `AT+QCSQ`, not `mmcli`.

AT=/dev/lte-at
log() { echo "dsgw210-lte-rat: $*"; }

# Send an AT command; return 0 only if the modem answers "OK" within ~3 s.
# Reader is started before the write so a fast reply is not missed.
at() {
	( timeout 3 cat "$AT" > /tmp/lte-rat.out 2>/dev/null & )
	sleep 0.3
	printf '%s\r' "$1" > "$AT" 2>/dev/null || return 1
	sleep 3
	grep -q 'OK' /tmp/lte-rat.out 2>/dev/null
}

# Wait for the AT port node to appear (modem USB enumeration).
w=0
while [ ! -e "$AT" ]; do
	w=$((w + 1))
	if [ "$w" -gt 30 ]; then
		log "$AT absent after ~60 s — skipping (NV setting persists from a prior boot)"
		exit 0
	fi
	sleep 2
done
stty -F "$AT" 115200 raw -echo 2>/dev/null || true

# The port node can exist several seconds before the modem firmware
# accepts AT commands — wait until it actually answers, else the QCFG
# writes are sent into the void.
w=0
until at 'AT'; do
	w=$((w + 1))
	if [ "$w" -gt 20 ]; then
		log "modem not answering AT after ~70 s — skipping (NV setting persists)"
		exit 0
	fi
	sleep 1
done

if at 'AT+QCFG="nwscanmode",3,1'; then log "nwscanmode=3 (LTE only) set"; else log "nwscanmode set: no OK from modem"; fi
if at 'AT+QCFG="iotopmode",0,1';  then log "iotopmode=0 (Cat-M1) set";   else log "iotopmode set: no OK from modem";  fi
rm -f /tmp/lte-rat.out
exit 0
