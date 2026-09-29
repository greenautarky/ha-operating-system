#!/bin/sh
# expect-findings: 1
# A lock FILE opened for writing next to the status file in the shared directory.
SHARE="${GA_EXAMPLE_SHARE:-/mnt/data/supervisor/share/example.json}"
LOCK="${GA_EXAMPLE_LOCK:-${SHARE}.lock}"
publish() {
    (
        flock 9
        render | /usr/libexec/ga-share-publish "$SHARE" 0644
    ) 9>"$LOCK"
}
