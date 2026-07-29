#!/bin/sh
# ga-stage-vendored-components regression suite.
#
# The staged custom_components tree is a CODE path: the ga_manager placer
# copies it into /config/custom_components/, and Home Assistant Core imports
# and executes whatever is in there for every enabled integration. So the
# security property under test is not "can it be read" but "who can write the
# tree the placer reads".
#
# Before this change the only staging root was /share, which is writable by
# every add-on declaring `share:rw`. The manifest.json version-gate does not
# help: it is a CHANGE gate, and a writer who controls the tree controls the
# version string too. These tests pin the trusted destination and the exact
# ordering guarantee the placer relies on.
#
# Pure host-side: needs only sh + coreutils/busybox. No device required.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "ga-stage-vendored-components (trusted staging root)"

STAGE="/usr/libexec/ga-stage-vendored-components"
[ -x "$STAGE" ] || STAGE="$SCRIPT_DIR/../../../buildroot-external/rootfs-overlay/usr/libexec/ga-stage-vendored-components"

run_test "GSV-01" "stager present + executable" "test -x '$STAGE'"

WORK="$(mktemp -d 2>/dev/null || echo /tmp/gsv_$$)"
SRC="$WORK/rootfs/usr/share/ga/custom_components"
SHARE="$WORK/share/ga-custom-components"
ADDONS="$WORK/addons/data"
PRIV_PARENT="$ADDONS/99f1cad4_ga_manager"
PRIV="$PRIV_PARENT/ga-custom-components"

mkdir -p "$SRC/greenautarky_site" "$PRIV_PARENT" "$WORK/share"
printf '{"domain":"greenautarky_site","version":"1.4.0"}\n' > "$SRC/greenautarky_site/manifest.json"
printf '# genuine GA component\n' > "$SRC/greenautarky_site/__init__.py"
# A stray non-component file must never be staged.
printf 'not a component\n' > "$SRC/VENDORED.md"

run_stage() {
  GA_STAGE_SRC="$SRC" \
  GA_STAGE_SHARE_DST="$SHARE" \
  GA_STAGE_PRIV_GLOB="$ADDONS/*_ga_manager" \
  sh "$STAGE" >/dev/null 2>&1
}

# --- both destinations get the component ------------------------------------
run_stage
run_test "GSV-02" "stages into the addon-private (trusted) root" \
  "test -f '$PRIV/greenautarky_site/manifest.json'"
run_test "GSV-03" "still stages into /share for older addons (compat)" \
  "test -f '$SHARE/greenautarky_site/manifest.json'"
run_test "GSV-04" "component payload is copied, not just the manifest" \
  "grep -q 'genuine GA component' '$PRIV/greenautarky_site/__init__.py'"
run_test "GSV-05" "a non-component file is not staged" \
  "test ! -e '$PRIV/VENDORED.md' && test ! -e '$SHARE/VENDORED.md'"

# --- THE security property --------------------------------------------------
# An add-on with share:rw rewrites the /share tree and bumps the version, which
# is what defeats the version-gate. The trusted copy must be unaffected, so the
# placer (which prefers it) never sees the tampered code.
printf 'import os; os.system("id")\n' > "$SHARE/greenautarky_site/__init__.py"
printf '{"domain":"greenautarky_site","version":"9.9.9"}\n' > "$SHARE/greenautarky_site/manifest.json"

run_test "GSV-10" "tampering /share does not reach the trusted copy" \
  "grep -q 'genuine GA component' '$PRIV/greenautarky_site/__init__.py'"
run_test "GSV-11" "trusted copy keeps the OS version, not the forged one" \
  "grep -q '1.4.0' '$PRIV/greenautarky_site/manifest.json'"

# The next boot must repair the tampered compat tree rather than accept it:
# the forged manifest differs from the OS one, so the version-gate re-stages.
run_stage
run_test "GSV-12" "next boot restores the tampered /share tree from the rootfs" \
  "grep -q 'genuine GA component' '$SHARE/greenautarky_site/__init__.py'"

# --- symlink hardening applies to BOTH roots (Vuln-2 class) -----------------
VICTIM="$WORK/victim"
mkdir -p "$VICTIM"
printf 'ORIGINAL\n' > "$VICTIM/keepme"
rm -rf "$SHARE"
ln -sf "$VICTIM" "$SHARE"
run_stage
run_test "GSV-20" "a symlinked staging root is not written through" \
  "test -f '$VICTIM/keepme' && grep -q ORIGINAL '$VICTIM/keepme'"
run_test "GSV-21" "symlinked staging root is replaced by a real directory" \
  "test -d '$SHARE' && test ! -L '$SHARE'"

# --- no addon installed yet -------------------------------------------------
# The glob matches nothing before ga_manager is installed. That must not stop
# the compat staging, and must not fail the boot.
rm -rf "$ADDONS" "$SHARE"
run_stage
run_test "GSV-30" "missing addon data dir still stages the compat copy" \
  "test -f '$SHARE/greenautarky_site/manifest.json'"
run_test "GSV-31" "missing addon data dir exits 0 (must never block boot)" \
  "GA_STAGE_SRC='$SRC' GA_STAGE_SHARE_DST='$SHARE' GA_STAGE_PRIV_GLOB='$ADDONS/*_ga_manager' sh '$STAGE' >/dev/null 2>&1"

# --- missing source ---------------------------------------------------------
run_test "GSV-40" "absent vendored source exits 0" \
  "GA_STAGE_SRC='$WORK/nope' GA_STAGE_SHARE_DST='$SHARE' GA_STAGE_PRIV_GLOB='$ADDONS/*_ga_manager' sh '$STAGE' >/dev/null 2>&1"

rm -rf "$WORK"
suite_end
