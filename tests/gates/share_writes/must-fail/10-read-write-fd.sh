#!/bin/sh
# expect-findings: 1
# <> opens for read AND write, creating the file.
SHARE=/mnt/data/supervisor/share/example.json
: 4<>"$SHARE"
