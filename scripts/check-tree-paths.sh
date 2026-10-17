#!/usr/bin/env bash
# check-tree-paths.sh — hold scripts/lib/tree-paths.sh to reality.
#
# A gate that names a path that is gone inspects zero files and reports green.
# This check fails closed on that:
#   1. every path in the map exists; directories are non-empty, files non-empty;
#      GA_HAOS_DIR (when mapped) must be a submodule: a gitlink in the index, so
#      an uninitialised CI checkout (empty dir) passes and a plain copied
#      directory in its place fails;
#   2. the map yields at least MIN_PATHS entries (a map that lost its entries
#      would otherwise pass over zero items);
#   3. every `paths:` filter in .github/workflows matches >=1 tracked file
#      (a filter that matches nothing silently stops its workflow triggering);
#   4. every pull_request `branches:` filter admits feat/** (the 1.6 integration
#      branch is feat/1.6-haos18; a PR into it must get lint + version check);
#   5. version-check.yml's filter covers the GA layer dir and every board dir
#      of the map (a moved layout must not drop the version check).
#
# Usage: check-tree-paths.sh [ROOT]   (ROOT defaults to the repo root; a git work tree)
# Exit: 0 ok · 1 violation · 2 cannot run (missing map / not a git tree)
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MIN_PATHS=5      # pinned: layer + version file + 3 per board
MIN_FILTERS=5    # pinned: filters inspected across the workflows
MIN_BRANCH_FILTERS=3   # pinned: lint, version-check, telegraf-config-check

MAP="$ROOT/scripts/lib/tree-paths.sh"
[ -f "$MAP" ] || { echo "ERROR: path map not found: $MAP" >&2; exit 2; }
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
	|| { echo "ERROR: $ROOT is not a git work tree" >&2; exit 2; }
# shellcheck source=lib/tree-paths.sh
. "$MAP"

bad=0
fail() { echo "FAIL: $*"; bad=1; }

# --- 1+2: the map itself ----------------------------------------------------
is_gitlink() { git -C "$ROOT" ls-files -s -- "$1" | awk '$1=="160000" && $4==P {f=1} END {exit !f}' P="$1"; }
n=0
while read -r name p; do
	[ -n "$name" ] || continue
	n=$((n+1))
	if [ "$p" = "<undefined>" ]; then fail "$name is not defined in the map"; continue; fi
	if [ "$name" = GA_HAOS_DIR ]; then
		is_gitlink "$p" || fail "$name: not a submodule (no gitlink in the index): $p"
		continue
	fi
	if [ -d "$ROOT/$p" ]; then
		[ -n "$(ls -A "$ROOT/$p")" ] || fail "$name: directory is empty: $p"
	elif [ -f "$ROOT/$p" ]; then
		[ -s "$ROOT/$p" ] || fail "$name: file is empty: $p"
	else
		fail "$name: path does not exist: $p"
	fi
done < <(ga_tree_paths)
[ "$n" -ge "$MIN_PATHS" ] || fail "map yields only $n paths (need >= $MIN_PATHS) — inspected too little"
echo "map: $n paths inspected"

# --- 3: workflow path filters ----------------------------------------------
f=0
vc_filters=""
for wf in "$ROOT"/.github/workflows/*.y*ml; do
	[ -f "$wf" ] || continue
	# `paths:` list items, quoted or bare, until the first non-item line.
	pats="$(awk '
		/^[[:space:]]*paths:[[:space:]]*$/ { inp=1; next }
		inp && /^[[:space:]]*-[[:space:]]/ {
			s=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",s); gsub(/^["\x27]|["\x27][[:space:]]*(#.*)?$/,"",s); sub(/[[:space:]]+#.*$/,"",s)
			print s; next }
		inp && /^[[:space:]]*(#.*)?$/ { next }
		{ inp=0 }' "$wf")"
	[ -n "$pats" ] || continue
	while IFS= read -r pat; do
		[ -n "$pat" ] || continue
		case "$pat" in '!'*) continue ;; esac
		f=$((f+1))
		cnt="$(git -C "$ROOT" ls-files -- ":(glob)$pat" | wc -l)"
		[ "$cnt" -gt 0 ] || fail "$(basename "$wf"): paths filter matches no tracked file: $pat"
		[ "$(basename "$wf")" = version-check.yml ] && vc_filters="$vc_filters
$pat"
	done <<<"$pats"
done
[ "$f" -ge "$MIN_FILTERS" ] || fail "only $f workflow path filters inspected (need >= $MIN_FILTERS)"
echo "filters: $f workflow path filters inspected"

# --- 4: PR branch filters admit feat/** --------------------------------------
bf=0
for wf in "$ROOT"/.github/workflows/*.y*ml; do
	[ -f "$wf" ] || continue
	line="$(awk '/^[[:space:]]*pull_request:[[:space:]]*$/ {inp=1; next}
		inp && /^[[:space:]]*branches:/ {print; exit}
		inp && /^[[:space:]]{0,3}[a-z_]+:/ {exit}' "$wf")"
	[ -n "$line" ] || continue
	bf=$((bf+1))
	case "$line" in *"feat/**"*) ;; *) fail "$(basename "$wf"): pull_request branches filter omits feat/**: ${line#"${line%%[![:space:]]*}"}" ;; esac
done
[ "$bf" -ge "$MIN_BRANCH_FILTERS" ] || fail "only $bf pull_request branch filters inspected (need >= $MIN_BRANCH_FILTERS)"
echo "branch filters: $bf pull_request branch filters inspected"

# --- 5: version-check.yml covers the map ------------------------------------
need="$GA_LAYER_DIR"
for b in $GA_BOARDS; do need="$need $(ga_board_var BOARD_DIR "$b" || echo UNDEFINED_BOARD_DIR_"$b")"; done
for d in $need; do
	covered=0
	while IFS= read -r pat; do
		case "$pat" in
			*/'**') case "$d/" in "${pat%\*\*}"*) covered=1 ;; esac ;;
		esac
	done <<<"$vc_filters"
	[ "$covered" = 1 ] || fail "version-check.yml paths filter does not cover ${d}/**"
done

[ "$bad" -eq 0 ] && echo "OK: tree-paths map matches the tree"
exit "$bad"
