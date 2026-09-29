#!/bin/sh
# expect-findings: 1
# Appending to a log in the shared directory.
LOG=/mnt/data/supervisor/share/example.jsonl
echo '{"x":1}' >> "$LOG"
