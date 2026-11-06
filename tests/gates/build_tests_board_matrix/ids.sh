#!/bin/bash
# ids.sh STATUS < runner-output -- the test IDs that ended in STATUS (PASS|FAIL|SKIP), one per line, sorted
# unique. An ID is the text after the status up to the first ':' / ' ' / '(' ("VER-09", "SRC-14a..c").
grep -E "^ +${1} " | sed -E "s/^ +${1} +([^ :(]+).*/\1/" | LC_ALL=C sort -u
