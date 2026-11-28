#!/usr/bin/env bash
# The LIVE scripts/check-patch-version-dirs.sh against committed file lists, and on this tree.
set -uo pipefail
H="$(cd "$(dirname "$0")" && pwd)"; C="$H/../../../scripts/check-patch-version-dirs.sh"
[ -x "$C" ] || { echo "FATAL: $C missing"; exit 1; }
ran=0; fails=0
t() { # <label> <want rc> <want text> <args...>
  local l="$1" w="$2" x="$3" o rc; shift 3; o="$("$C" "$@" 2>&1)"; rc=$?; ran=$((ran+1))
  if [ "$rc" = "$w" ] && grep -qF -- "$x" <<<"$o"; then echo "  ok    $l"; else fails=$((fails+1)); echo "  FAIL  $l (rc=$rc)"; echo "$o" | tail -3; fi
}
for f in "$H"/must-flag/*.txt; do t "must-flag $(basename "$f" .txt)" 1 "Buildroot skips" --list "$f"; done
for f in "$H"/must-pass/*.txt; do t "must-pass $(basename "$f" .txt)" 0 "0 with a version directory" --list "$f"; done
t "no patch directory at all = cannot check" 2 "0 inspected" --list "$H/nothing.txt"
t "this tree is clean" 0 "0 with a version directory"
echo "$ran cases, $fails failed"; [ "$ran" -ge 9 ] && [ "$fails" -eq 0 ]
