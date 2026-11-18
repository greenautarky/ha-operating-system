#!/bin/sh
# On-device (DSGW-210): exactly one rtw88 blob, and it is the pinned one (RF gate R3/R14, #2186).
# Pinned constant (rule 7, not read from the image): sha256 measured on BOSv1.6.0-dev12, 2026-11-18.
PIN=2ef409bc418549fcf294061dd0cae1fc22fd9da79b60524950b25de18732f3f0
L=$(ls /lib/firmware/rtw88 2>/dev/null)
[ "$L" = rtw8821c_fw.bin ] && echo "  PASS  RTB-01: /lib/firmware/rtw88 holds exactly rtw8821c_fw.bin" || { echo "  FAIL  RTB-01: /lib/firmware/rtw88 = '$(echo $L)'"; rc=1; }
S=$(sha256sum /lib/firmware/rtw88/rtw8821c_fw.bin 2>/dev/null | cut -d' ' -f1)
[ "$S" = "$PIN" ] && echo "  PASS  RTB-02: blob sha256 = pinned" || { echo "  FAIL  RTB-02: sha256 '${S:-none}' != pinned (a linux-firmware bump needs a reference-change PR)"; rc=1; }
exit "${rc:-0}"
