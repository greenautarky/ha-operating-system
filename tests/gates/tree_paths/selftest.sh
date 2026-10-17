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
# Submodules (gitlinks) are not copied: their checkout is another repository.
# They are recreated in the copy's index as gitlinks, which is all the gate reads.
gitlinks="$(git -C "$repo" ls-files -s | awk '$1=="160000" {print $2" "$4}')"
( cd "$repo" && git ls-files -co --exclude-standard -z \
	| { if [ -n "$gitlinks" ]; then grep -zvxF -f <(awk '{print $2}' <<<"$gitlinks"); else cat; fi; } \
	| tar --null -T - -cf - ) | tar -x -C "$live"
git -C "$live" init -q && git -C "$live" add -A -f >/dev/null 2>&1
while read -r sha path; do
	[ -n "$path" ] && git -C "$live" update-index --add --cacheinfo "160000,$sha,$path"
done <<<"$gitlinks"
sed -i 's#^GA_LAYER_DIR=.*#GA_LAYER_DIR=buildroot-external-moved#' "$live/scripts/lib/tree-paths.sh"
verdict "live-map-stale-layer" must-fail "$live" "path does not exist: buildroot-external-moved"
n=$((n+1))
# GA_HAOS_DIR must be a submodule: a gitlink passes (CI never initialises it, so
# the directory is empty there), a plain directory in its place fails.
hg="$tmp/haos-gitlink"; mkrepo "$here/must-pass/good-minimal" "$hg"
printf 'GA_HAOS_DIR=haos\n' >> "$hg/scripts/lib/tree-paths.sh"
sed -i "s#^ga_tree_paths() {#ga_tree_paths() {\n\tprintf '%s %s\\\\n' GA_HAOS_DIR \"\$GA_HAOS_DIR\"#" "$hg/scripts/lib/tree-paths.sh"
git -C "$hg" update-index --add --cacheinfo "160000,$(git -C "$hg" rev-parse HEAD),haos"
grep -q "GA_HAOS_DIR haos" <(sh -c ". \"$hg/scripts/lib/tree-paths.sh\"; ga_tree_paths") || { echo "  FAIL  haos-gitlink fixture does not map GA_HAOS_DIR"; bad=1; }
verdict "haos-gitlink" must-pass "$hg"; n=$((n+1)); np=$((np+1))
hd="$tmp/haos-plain-dir"; mkrepo "$hg" "$hd"
git -C "$hd" rm -q --cached haos 2>/dev/null; mkdir -p "$hd/haos" && echo x > "$hd/haos/f" && git -C "$hd" add -f haos/f
verdict "haos-plain-dir" must-fail "$hd" "GA_HAOS_DIR: not a submodule"; n=$((n+1))
[ "$n" -ge 12 ] && [ "$np" -ge 3 ] || { echo "FAIL: only $n cases ($np must-pass) ran"; exit 1; }
echo "$n cases ran"
exit "$bad"
