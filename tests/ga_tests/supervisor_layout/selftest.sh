#!/usr/bin/env bash
# Self-test of scripts/check-supervisor-layout.sh over REAL image listings.
# bad-*  = must exit 1 (add-on base layout) or 2 (nothing to judge)
# good-* = must exit 0 (includes the shipping 2025.11.5.10 and the aarch64 image)
# The script under test is the LIVE one; the listings were exported from the
# actual images (docker export | tar -t, trimmed to the s6 paths).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/../../../scripts/check-supervisor-layout.sh"
FX="$HERE/fixtures"
[ -f "$S" ] || { echo "FAIL: $S not found"; exit 1; }
n=0; bad=0
expect() {  # <fixture> <want-rc>
  n=$((n+1)); bash "$S" --listing "$FX/$1" >/dev/null 2>&1; got=$?
  if [ "$got" = "$2" ]; then echo "  ok    $1 -> $got"; else echo "  WRONG $1 -> $got, want $2"; bad=$((bad+1)); fi
}
expect bad-armv7-2026.10.5.1.lst 1
expect bad-no-supervisor-service.lst 1
expect bad-empty.lst 2
expect good-armv7-2025.11.5.10.lst 0
expect good-aarch64-2026.10.5.1.lst 0
expect good-armv7-fixed-layered.lst 0
[ "$n" -ge 6 ] || { echo "FAIL: only $n cases ran"; exit 1; }
[ "$bad" -eq 0 ] && echo "supervisor_layout selftest: $n cases ok" || { echo "supervisor_layout selftest: $bad of $n WRONG"; exit 1; }
