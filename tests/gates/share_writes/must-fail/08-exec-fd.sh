#!/bin/sh
# expect-findings: 1
# A long-lived fd opened on a path in the shared directory.
exec 3>/mnt/data/supervisor/share/example.state
