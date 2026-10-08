#!/usr/bin/env bash
# Runs the LIVE scripts/check-unit-refs.py against every fixture tree:
# must-fail/* must exit 1 AND print the reason named in its `expect` file
# (failing for another reason leaves the rule under test unproven), must-pass/*
# must exit 0. Then the fail-closed path: a tree without unit files must exit 2.
# Fewer fixtures than pinned below = FAIL (a self-test over nothing is no test).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
gate="$here/../../../scripts/check-unit-refs.py"
[ -x "$gate" ] || { echo "FAIL: lint not found or not executable: $gate"; exit 1; }

n=0 nf=0 np=0 bad=0
for d in "$here"/must-fail/*/ "$here"/must-pass/*/; do
  [ -d "$d" ] || continue
  kind="$(basename "$(dirname "$d")")"; name="$(basename "$d")"
  n=$((n+1))
  out="$("$gate" "$d" 2>&1)"; rc=$?
  if [ "$kind" = must-fail ]; then
    nf=$((nf+1))
    want="$(head -1 "$d/expect" 2>/dev/null)"
    if [ "$rc" -eq 1 ] && [ -n "$want" ] && grep -qF -- "$want" <<<"$out"; then
      echo "  ok    must-fail/$name (rc=$rc) $(grep -F -- "$want" <<<"$out" | head -1 | sed 's#.*/must-fail/[^/]*/##')"
    else
      echo "  FAIL  must-fail/$name (rc=$rc, want: ${want:-<no expect file>})"; sed 's/^/        /' <<<"$out"; bad=1
    fi
  else
    np=$((np+1))
    if [ "$rc" -eq 0 ]; then
      echo "  ok    must-pass/$name (rc=0) ${out##*$'\n'}"
    else
      echo "  FAIL  must-pass/$name (rc=$rc)"; sed 's/^/        /' <<<"$out"; bad=1
    fi
  fi
done

# Fail closed: a tree with no unit files is exit 2, never a pass.
empty="$(mktemp -d)"; trap 'rm -rf "$empty"' EXIT
mkdir -p "$empty/etc/systemd/system"; echo 'not a unit' > "$empty/etc/systemd/system/README"
"$gate" "$empty" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then echo "  ok    zero unit files -> rc=2"; else echo "  FAIL  zero unit files -> rc=$rc (want 2)"; bad=1; fi

[ "$nf" -ge 9 ] && [ "$np" -ge 4 ] || { echo "FAIL: only $nf must-fail / $np must-pass fixtures inspected"; exit 1; }
echo "$n fixtures inspected ($nf must-fail, $np must-pass) + fail-closed check"
exit "$bad"
