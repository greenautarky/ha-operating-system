#!/bin/sh
# Comments may describe `printf x > /mnt/data/supervisor/share/example.json`.
# Writes to files OUTSIDE the shared directory are not this gate's business.
SHARE=/mnt/data/supervisor/share/example.json
STATE=/run/example.state
printf '1\n' > "$STATE"   # > "$SHARE" in a trailing comment
cat "$SHARE" > /dev/null 2>&1
echo "status at $SHARE" >&2
[ "$(( 3 > 2 ))" = 1 ] && echo ok > /run/example.ok
