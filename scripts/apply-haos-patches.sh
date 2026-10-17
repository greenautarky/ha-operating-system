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
#   scripts/apply-haos-patches.sh --cat <path>
#                                           print <path> (relative to haos/, e.g.
#                                           buildroot-external/package/hassio/hassio.mk)
#                                           as the build sees it: upstream with the
#                                           whole set applied, from the throwaway
#                                           index. Working tree untouched; a file
#                                           the set deletes or that does not exist
#                                           fails. For gates and tests that judge a
#                                           GA delta of an upstream file.
#   scripts/apply-haos-patches.sh --export <dir> <path>...
#                                           the same, written to <dir>/<path> with
#                                           the file's mode (for consumers that need
#                                           a file to run, source or copy).
#
# Patch set, in this order (revert walks it backwards):
#   1. $GA_HAOS_PATCH_DIR/*.patch        build fixes to upstream files
#   2. $GA_LAYER_DIR/patches-haos/*.patch GA deltas of upstream HAOS files that
#                                        cannot move into the GA layer as files
# Both directories come from scripts/lib/tree-paths.sh.
#
# Rules — every one of them fails, none of them skips:
#   * apply always starts from upstream: every applied patch is reverted
#     (backwards), then the whole set is applied in order, so a patch always
#     meets exactly the tree it was written against, also when two patches
#     touch one file. A patch that does not apply there stops the build; a HAOS
#     bump that breaks a patch must not produce an image without the fix. A
#     patch upstream already contains stops it too (delete the patch).
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
if [ "$MODE" != "--cat" ] && [ "$MODE" != "--export" ]; then
	echo "apply-haos-patches: ${#PATCHES[@]} patch(es), haos at $(git -C "$_haos_dir" rev-parse --short=12 HEAD)"
fi

# All paths the patch set touches (one per line).
touched() { for p in "${PATCHES[@]}"; do git -C "$_haos_dir" apply --numstat "$p" | cut -f3; done | sort -u; }

# check_set — validate the whole set against upstream HEAD in a throwaway index
# (the working tree is neither read nor written): in order, each patch must
# apply on upstream + the patches before it, and must not be contained there
# already (it would reverse-apply). Prints one verdict per patch; returns 1 on
# the first bad one.
check_set() {
	local idx p n rc=0
	idx="${_KEEP_IDX:-$(mktemp)}"
	GIT_INDEX_FILE="$idx" git -C "$_haos_dir" read-tree HEAD
	for p in "${PATCHES[@]}"; do
		n=$(basename "$p")
		if GIT_INDEX_FILE="$idx" git -C "$_haos_dir" apply --cached --check -R "$p" 2>/dev/null \
		   && ! GIT_INDEX_FILE="$idx" git -C "$_haos_dir" apply --cached --check "$p" 2>/dev/null; then
			printf '  %-16s %s\n' in-upstream "$n"
			echo "apply-haos-patches: $n is already contained in upstream haos/ — delete the patch" >&2
			rc=1; break
		elif GIT_INDEX_FILE="$idx" git -C "$_haos_dir" apply --cached "$p" 2>/dev/null; then
			printf '  %-16s %s\n' ok "$n"
		else
			printf '  %-16s %s\n' broken "$n"
			GIT_INDEX_FILE="$idx" git -C "$_haos_dir" apply --cached --check -v "$p" >&2 || true
			echo "apply-haos-patches: $n neither applies nor is already applied to haos/ — rebase the patch onto the new pin (or drop it if upstream took it)" >&2
			rc=1; break
		fi
	done
	[ -n "${_KEEP_IDX:-}" ] || rm -f "$idx"
	return $rc
}

# revert_all — walk the set BACKWARDS and reverse every patch that is applied.
# Backwards matters: when two patches touch one file, the later one is only
# reversible first. A patch that does not reverse-apply is skipped here, and
# judged by the end state instead: every touched path must be back at upstream
# HEAD, else the tree is in a state no prefix of the patch set explains.
revert_all() {
	local i p
	for (( i=${#PATCHES[@]}-1; i>=0; i-- )); do
		p="${PATCHES[$i]}"
		if git -C "$_haos_dir" apply --check -R "$p" 2>/dev/null; then
			git -C "$_haos_dir" apply -R "$p"; echo "  reverted         $(basename "$p")"
		fi
	done
	mapfile -t _t < <(touched)
	if ! git -C "$_haos_dir" diff --quiet HEAD -- "${_t[@]}" \
	   || [ -n "$(git -C "$_haos_dir" ls-files --others --exclude-standard -- "${_t[@]}")" ]; then
		git -C "$_haos_dir" status --short -- "${_t[@]}" >&2
		die "patched paths in haos/ are in an unknown state (not upstream after reverting every applied patch) — refusing to touch them"
	fi
}

case "$MODE" in
apply|--apply)
	# Validate the set first (nothing touched yet), then always from pristine:
	# revert what is applied, apply the whole set in order. Each patch thus meets
	# exactly the tree it was written against (upstream + the patches before
	# it), also when several patches touch one file.
	check_set >/dev/null || die "patch set does not apply to haos/ @ $(git -C "$_haos_dir" rev-parse --short=12 HEAD) (see above)"
	revert_all
	for p in "${PATCHES[@]}"; do
		git -C "$_haos_dir" apply "$p" || die "$(basename "$p") failed to apply after validation"
		echo "  applied          $(basename "$p")"
	done
	;;
--revert)
	revert_all
	;;
--check)
	check_set; exit $?
	;;
--cat|--export)
	if [ "$MODE" = "--cat" ]; then
		[ $# -eq 2 ] || die "usage: --cat <path relative to haos/>"
		out=""; rels=("$2")
	else
		[ $# -ge 3 ] || die "usage: --export <dir> <path relative to haos/>..."
		out="$2"; rels=("${@:3}")
	fi
	_KEEP_IDX=$(mktemp); trap 'rm -f "$_KEEP_IDX"' EXIT
	check_set >/dev/null || die "patch set does not apply to haos/ — cannot show the tree as the build sees it"
	for rel in "${rels[@]}"; do
		fmode="" blob=""
		read -r fmode blob _ < <(GIT_INDEX_FILE="$_KEEP_IDX" git -C "$_haos_dir" ls-files -s -- "$rel") || true
		[ -n "${blob:-}" ] || die "$rel is not in haos/ with the patch set applied (deleted by a patch, or no such file)"
		if [ -z "$out" ]; then
			git -C "$_haos_dir" cat-file blob "$blob"
		else
			mkdir -p "$out/$(dirname "$rel")"
			git -C "$_haos_dir" cat-file blob "$blob" > "$out/$rel"
			[ "$fmode" = 100755 ] && chmod 0755 "$out/$rel" || chmod 0644 "$out/$rel"
		fi
	done
	exit 0
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
