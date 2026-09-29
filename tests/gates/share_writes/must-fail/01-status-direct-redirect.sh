#!/bin/sh
# expect-findings: 1
# A status line redirected straight onto its path in the shared directory.
STATUS="${GA_EXAMPLE_STATUS:-/mnt/data/supervisor/share/example.json}"
write_status() {
    printf '{"state":"%s"}\n' "$1" \
        > "$STATUS"
}
