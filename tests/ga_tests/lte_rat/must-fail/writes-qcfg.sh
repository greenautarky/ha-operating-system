#!/bin/sh
# must-fail fixture: the pre-#2187 behaviour — a QCFG SET form (value + save flag).
AT=${GA_LTE_AT:-/dev/lte-at}
stty -F "$AT" 115200 raw -echo 2>/dev/null || true
printf 'AT\r' > "$AT"; sleep 0.5
printf 'AT+QCFG="nwscanmode",3,1\r' > "$AT"; sleep 0.5
printf 'AT+QCFG="iotopmode",0,1\r' > "$AT"; sleep 0.5
exit 0
