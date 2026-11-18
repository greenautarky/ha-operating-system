#!/usr/bin/env sh
# 60-rtw88-single-blob.sh — the DSGW-210 ships exactly ONE rtw88 firmware blob,
# the one its RTL8821CS uses (Odoo #2186, CE RF-invariant gate R14; decision
# Thomas 2026-11-18). BR2_PACKAGE_LINUX_FIRMWARE_RTL_RTW88=y installs the whole
# rtw88 set (10 blobs, measured on BOSv1.6.0-dev12); everything else is removed
# here. Fails closed: a missing rtw8821c_fw.bin means the image has no Wi-Fi.
set -eu
TARGET_DIR="${1:-}"
KEEP="${GA_RTW88_KEEP:-rtw8821c_fw.bin}"
[ -n "$TARGET_DIR" ] && [ -d "$TARGET_DIR" ] || { echo "ERROR: TARGET_DIR not provided or invalid" >&2; exit 1; }
D="$TARGET_DIR/lib/firmware/rtw88"
[ -f "$D/$KEEP" ] || { echo "ERROR: $D/$KEEP missing - the DSGW-210 Wi-Fi would have no firmware" >&2; exit 1; }
removed=0
for f in "$D"/* "$D"/.[!.]*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ "$(basename "$f")" = "$KEEP" ] && continue
    rm -rf "$f"; removed=$((removed + 1))
done
left=$(find "$D" -mindepth 1 | wc -l)
[ "$left" -eq 1 ] || { echo "ERROR: $D holds $left entries after pruning, want exactly 1 ($KEEP)" >&2; exit 1; }
echo "rtw88: kept $KEEP, removed $removed other firmware file(s)"
