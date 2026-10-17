#!/usr/bin/env bash
# Runs the LIVE scripts/check-tree-paths.sh over every fixture tree (copied into
# a throwaway git repo, because the gate lists tracked files):
#   must-pass/<n>/        rc 0
#   must-fail/<n>/        rc 1 AND the output contains the first line of
#                         must-fail/<n>.expect (failing for another reason leaves
#                         the rule under test unproven)
# plus two live-tree cases: the real tree is green, and the real tree with a
# stale path injected into the REAL map is red. Zero fixtures = FAIL.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
gate="$repo/scripts/check-tree-paths.sh"
[ -x "$gate" ] || { echo "FAIL: gate not found: $gate"; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bad=0 n=0 np=0

mkrepo() { # SRC DST
	mkdir -p "$2" && cp -a "$1/." "$2/" \
		&& git -C "$2" init -q && git -C "$2" add -A -f \
		&& git -C "$2" -c user.email=t@t -c user.name=t commit -qm fixture
}
verdict() { # LABEL KIND ROOT [EXPECT]
	local out rc ok=0
	out="$("$gate" "$3" 2>&1)"; rc=$?
	if [ "$2" = must-pass ]; then [ "$rc" -eq 0 ] && ok=1
	else [ "$rc" -eq 1 ] && grep -qF -- "$4" <<<"$out" && ok=1; fi
	if [ "$ok" = 1 ]; then echo "  ok    $2/$1 (rc=$rc)"
	else echo "  FAIL  $2/$1 (rc=$rc, want ${4:-rc 0}) :: $(tr '\n' '|' <<<"$out")"; bad=1; fi
}
for d in "$here"/must-pass/*/; do
	[ -d "$d" ] || continue; name="$(basename "$d")"; n=$((n+1)); np=$((np+1))
	mkrepo "$d" "$tmp/p-$name" && verdict "$name" must-pass "$tmp/p-$name"
done
for d in "$here"/must-fail/*/; do
	[ -d "$d" ] || continue; name="$(basename "$d")"; n=$((n+1))
	exp="$(head -1 "$here/must-fail/$name.expect" 2>/dev/null)"
	[ -n "$exp" ] || { echo "  FAIL  must-fail/$name has no .expect"; bad=1; continue; }
	mkrepo "$d" "$tmp/f-$name" && verdict "$name" must-fail "$tmp/f-$name" "$exp"
done
# Live tree: green as committed, red with a stale path in the live map.
out="$("$gate" "$repo" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "  ok    live tree green"; else echo "  FAIL  live tree rc=$rc :: $out"; bad=1; fi
n=$((n+1)); np=$((np+1))
live="$tmp/live"; mkdir -p "$live"
# tracked + not-yet-committed files of the live tree (so it works pre-commit too)
( cd "$repo" && git ls-files -co --exclude-standard -z | tar --null -T - -cf - ) | tar -x -C "$live"
git -C "$live" init -q && git -C "$live" add -A -f >/dev/null 2>&1
sed -i 's#^GA_LAYER_DIR=.*#GA_LAYER_DIR=buildroot-external-moved#' "$live/scripts/lib/tree-paths.sh"
verdict "live-map-stale-layer" must-fail "$live" "path does not exist: buildroot-external-moved"
n=$((n+1))
[ "$n" -ge 10 ] && [ "$np" -ge 3 ] || { echo "FAIL: only $n cases ($np must-pass) ran"; exit 1; }
echo "$n cases ran"
exit "$bad"
