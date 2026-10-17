#!/usr/bin/env bash
# apply-haos-patches.sh — apply (or revert) GA's patches to the haos/ submodule
# working tree. haos/ is an UNMODIFIED upstream Home Assistant OS checkout; the
# only changes its working tree may carry are the ones these patch files make.
#
#   scripts/apply-haos-patches.sh           apply every patch, idempotently
#   scripts/apply-haos-patches.sh --revert  revert every applied patch
#   scripts/apply-haos-patches.sh --check   report state, change nothing
#   scripts/apply-haos-patches.sh --list    print the ordered patch list, one
#                                           path per line (the single definition
#                                           of the patch set)
#
# Patch set, in this order (revert walks it backwards):
#   1. $GA_HAOS_PATCH_DIR/*.patch        build fixes to upstream files
#   2. $GA_LAYER_DIR/patches-haos/*.patch GA deltas of upstream HAOS files that
#                                        cannot move into the GA layer as files
# Both directories come from scripts/lib/tree-paths.sh.
#
# Rules — every one of them fails, none of them skips:
#   * A patch that neither applies nor is already applied stops the build. A
#     HAOS bump that breaks a patch must not produce an image without the fix.
#   * After applying, every modified/untracked path in haos/ (nested buildroot
#     submodule included) must be one a patch touches. Anything else is a hand
#     edit of upstream.
#   * An empty patch set is an error: zero patches applied means the layout or
#     the map is wrong, not that there is nothing to do.
#
# Overrides (for the self-test only): HAOS_DIR, GA_HAOS_PATCH_DIR, GA_LAYER_DIR.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/tree-paths.sh
. "$REPO/scripts/lib/tree-paths.sh"
_haos_dir="${HAOS_DIR:-$REPO/$GA_HAOS_DIR}"
_patch_dir="${GA_HAOS_PATCH_DIR_OVERRIDE:-$REPO/$GA_HAOS_PATCH_DIR}"
_layer_patch_dir="${GA_LAYER_PATCH_DIR_OVERRIDE:-$REPO/$GA_LAYER_DIR/patches-haos}"
MODE="${1:-apply}"

die() { echo "apply-haos-patches: FAIL: $*" >&2; exit 1; }

shopt -s nullglob
PATCHES=("$_patch_dir"/*.patch "$_layer_patch_dir"/*.patch)
[ "${#PATCHES[@]}" -gt 0 ] || die "no patches found in $_patch_dir or $_layer_patch_dir"

if [ "$MODE" = "--list" ]; then
	printf '%s\n' "${PATCHES[@]}"
	exit 0
fi

[ -e "$_haos_dir/.git" ] || die "$_haos_dir is not initialised (run: git submodule update --init --recursive haos)"
echo "apply-haos-patches: ${#PATCHES[@]} patch(es), haos at $(git -C "$_haos_dir" rev-parse --short=12 HEAD)"

state() {   # prints applied | pending | broken
	if git -C "$_haos_dir" apply --check "$1" 2>/dev/null; then echo pending
	elif git -C "$_haos_dir" apply --check -R "$1" 2>/dev/null; then echo applied
	else echo broken
	fi
}

case "$MODE" in
apply|--apply)
	for p in "${PATCHES[@]}"; do
		n=$(basename "$p")
		case "$(state "$p")" in
		pending) git -C "$_haos_dir" apply "$p"; echo "  applied          $n" ;;
		applied)
			echo "  already applied  $n"
			# Applied, yet the files it touches equal upstream HEAD: upstream
			# itself carries the change now. The patch is dead weight.
			mapfile -t files < <(git -C "$_haos_dir" apply --numstat "$p" | cut -f3)
			if git -C "$_haos_dir" diff --quiet HEAD -- "${files[@]}"; then
				echo "  WARNING: upstream haos/ already contains $n — delete the patch" >&2
			fi
			;;
		broken)
			echo "  DOES NOT APPLY   $n" >&2
			git -C "$_haos_dir" apply --check -v "$p" >&2 || true
			die "$n neither applies nor is already applied to haos/ — rebase the patch onto the new pin (or drop it if upstream took it)"
			;;
		esac
	done
	;;
--revert)
	for (( i=${#PATCHES[@]}-1; i>=0; i-- )); do
		p="${PATCHES[$i]}"; n=$(basename "$p")
		case "$(state "$p")" in
		applied) git -C "$_haos_dir" apply -R "$p"; echo "  reverted         $n" ;;
		pending) echo "  not applied      $n" ;;
		broken)  die "$n is in an unknown state in haos/, refusing to touch it" ;;
		esac
	done
	;;
--check)
	rc=0
	for p in "${PATCHES[@]}"; do
		s=$(state "$p"); printf '  %-16s %s\n' "$s" "$(basename "$p")"
		[ "$s" = broken ] && rc=1
	done
	exit $rc
	;;
*) die "unknown mode '$MODE'" ;;
esac

# Stray-edit guard: the set of changed paths in haos/ must be a subset of the
# paths the patches touch (empty after --revert).
allowed=$(mktemp); actual=$(mktemp); trap 'rm -f "$allowed" "$actual"' EXIT
if [ "$MODE" != "--revert" ]; then
	for p in "${PATCHES[@]}"; do git -C "$_haos_dir" apply --numstat "$p" | cut -f3; done | sort -u > "$allowed"
fi
git -C "$_haos_dir" status --porcelain=v1 --untracked-files=all --ignore-submodules=none \
	| cut -c4- | sort -u > "$actual"
stray=$(comm -23 "$actual" "$allowed")
if [ -n "$stray" ]; then
	printf '%s\n' "$stray" | sed 's/^/  stray change in haos\/: /' >&2
	die "haos/ carries changes no patch explains"
fi
echo "apply-haos-patches: OK ($(wc -l < "$actual") path(s) changed in haos/, all from patches)"
