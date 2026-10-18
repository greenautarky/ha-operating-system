# shellcheck shell=bash
# ga-os-meta.sh — read and bump the OS version (VERSION_MAJOR.MINOR.SUFFIX) on
# the HAOS 18.x layout. Sourced by scripts/release.sh. No side effects on load.
#
# WHY THIS FILE EXISTS
#   Until HAOS 18.x the version lived in buildroot-external/meta, a file GA
#   owned, and release.sh edited it with sed. Since the lift `meta` is an
#   UPSTREAM file: MAJOR and MINOR come from the pinned haos/ submodule and only
#   the GA suffix is GA's, as one line of the patch
#   buildroot-external/patches-haos/0101-ga-meta-product-name.patch
#   (`+VERSION_SUFFIX="1.6"`). Editing meta would change nothing the build
#   reads; editing the patch is the release.
#
#   Fixtures: tests/gates/release_suffix/selftest.sh (run in CI) drives these
#   functions on copies of the LIVE patch and reads the result back through the
#   applier (the same read the build does).

GA_META_PATCH_REL="buildroot-external/patches-haos/0101-ga-meta-product-name.patch"

# ga_meta_cat REPO — the patched upstream meta as the build sees it.
# LAYER_PATCH_DIR_OVERRIDE (optional) points the applier at another patch dir.
ga_meta_cat() {
	"$1/scripts/apply-haos-patches.sh" --cat buildroot-external/meta
}

# ga_meta_get REPO KEY — VERSION_MAJOR | VERSION_MINOR | VERSION_SUFFIX from the
# patched meta. Prints the value; nonzero and nothing printed when the key is
# absent or the value empty-but-required is the caller's call (suffix may be "").
ga_meta_get() {
	ga_meta_cat "$1" | sed -n -E "s/^$2=\"([^\"]*)\".*/\1/p" | head -n 1
}

# ga_meta_set_suffix PATCH NEW — set the `+VERSION_SUFFIX="..."` line of the GA
# meta patch. Fails (patch untouched) unless the patch has EXACTLY ONE such line
# and NEW is a dotted number; verifies the edit by reading the line back.
ga_meta_set_suffix() {
	local patch="$1" new="$2" n
	[[ "$new" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "ga_meta_set_suffix: suffix '$new' is not a dotted number" >&2; return 1; }
	[[ -f "$patch" ]] || { echo "ga_meta_set_suffix: $patch not found" >&2; return 1; }
	n=$(grep -c '^+VERSION_SUFFIX=' "$patch" || true)
	[[ "$n" == 1 ]] || { echo "ga_meta_set_suffix: $patch has $n '+VERSION_SUFFIX=' lines, expected exactly 1" >&2; return 1; }
	sed -i -E "s|^\+VERSION_SUFFIX=.*|+VERSION_SUFFIX=\"$new\"|" "$patch"
	[[ "$(sed -n -E 's/^\+VERSION_SUFFIX="([^"]*)".*/\1/p' "$patch")" == "$new" ]] \
		|| { echo "ga_meta_set_suffix: edit of $patch did not take" >&2; return 1; }
}
