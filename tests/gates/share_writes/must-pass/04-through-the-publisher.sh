#!/bin/sh
# Writes that go through ga-share-publish, including a heredoc whose body
# contains redirect-like characters.
STATUS="${GA_EXAMPLE_STATUS:-/mnt/data/supervisor/share/example.json}"
PUBLISH="${GA_SHARE_PUBLISH:-/usr/libexec/ga-share-publish}"
printf '{"a":1}\n' | "$PUBLISH" "$STATUS" 0644 || echo "publish failed" >&2
/usr/libexec/ga-share-publish "$STATUS" 0644 <<EOF || true
{ "note": "a > b", "cmd": "x >> $STATUS" }
EOF
