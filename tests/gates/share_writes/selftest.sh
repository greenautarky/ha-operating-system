#!/bin/sh
# selftest.sh — the share-writes gate goes red on every known-bad shape and
# stays green on every known-good one, and refuses to pass over nothing.
#
# It runs the LIVE check.py (never a copy of its patterns) over:
#   must-fail/*.sh   each file MUST produce exactly its pinned number of
#                    findings (`# expect-findings: N`), exit 1
#   must-pass/*.sh   each file must produce none (exit 0)
#   an empty root    must FAIL (exit 2) — zero inspected files is not a pass
# and then over this repository's own overlays, which must be clean and must
# have yielded a non-trivial number of shell files.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/check.py"
[ -f "$CHECK" ] || { echo "FATAL: $CHECK missing"; exit 1; }

fails=0; ran=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fails=$((fails + 1)); }

echo "── must-fail fixtures (each must be flagged) ──"
for f in "$HERE"/must-fail/*.sh; do
  [ -e "$f" ] || continue
  ran=$((ran + 1))
  out="$(python3 "$CHECK" "$f" 2>&1)"; rc=$?
  n="$(printf '%s\n' "$out" | grep -c ': redirect into shared dir\|writes into shared dir')"
  # Each fixture pins how many writes it contains, so a rule that stops firing
  # is caught even when another rule still flags the same file.
  want="$(sed -n 's/^# expect-findings: \([0-9][0-9]*\)$/\1/p' "$f")"
  if [ -z "$want" ]; then bad "$(basename "$f") has no '# expect-findings: N' line"
  elif [ "$rc" -eq 1 ] && [ "$n" -eq "$want" ]; then ok "$(basename "$f") → $n finding(s)"
  else bad "$(basename "$f") → rc=$rc, $n finding(s), want $want: $out"; fi
done

echo "── must-pass fixtures (none may be flagged) ──"
for f in "$HERE"/must-pass/*.sh; do
  [ -e "$f" ] || continue
  ran=$((ran + 1))
  out="$(python3 "$CHECK" "$f" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then ok "$(basename "$f")"
  else bad "$(basename "$f") flagged (rc=$rc): $out"; fi
done

echo "── fail closed on an empty tree ──"
EMPTY="$(mktemp -d)"; trap 'rm -rf "$EMPTY"' EXIT
ran=$((ran + 1))
python3 "$CHECK" --root "$EMPTY" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "no shell files found → exit 2"
else bad "an empty tree returned rc=$rc (must be 2)"; fi

echo "── the live overlays ──"
ran=$((ran + 1))
out="$(python3 "$CHECK" 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
inspected="$(printf '%s\n' "$out" | sed -n 's/.*inspected \([0-9]*\) shell file.*/\1/p')"
if [ "$rc" -eq 0 ] && [ "${inspected:-0}" -ge 20 ]; then ok "live overlays clean over $inspected shell files"
else bad "live overlays: rc=$rc, inspected=${inspected:-?} (want rc 0 over >= 20 files)"; fi

echo
[ "$ran" -ge 10 ] || { echo "FATAL: only $ran checks ran"; exit 1; }
if [ "$fails" -eq 0 ]; then echo "share-writes selftest: $ran checks, all as expected"; exit 0; fi
echo "share-writes selftest: $fails of $ran checks wrong"; exit 1
