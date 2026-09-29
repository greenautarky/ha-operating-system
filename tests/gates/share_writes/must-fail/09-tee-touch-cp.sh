#!/bin/sh
# expect-findings: 3
# Commands that write their operands.
D=/mnt/data/supervisor/share
echo x | tee "$D/a.json" >/dev/null
touch "$D/.marker"
cp /etc/hostname "$D/hostname"
