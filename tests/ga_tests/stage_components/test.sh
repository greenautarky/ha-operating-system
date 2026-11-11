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

# --- newer-wins version gate (Odoo #1888) -----------------------------------
# A component delivered by the fm component-sync job is NEWER than the baked
# one. The old "manifest differs" gate rolled it back on every boot. Fixtures:
# MUST-KEEP (staged newer / equal) and MUST-RESTAGE (baked newer / staged
# missing / no version / garbage). 2.12.9 vs 2.12.12 pins numeric, not lexical.
# Trusted root only: /share is writable by other add-ons, so it stays a strict
# "differs" gate (GSV-12) and a forged higher version there must not stick.
vg_case() { # <id> <desc> <baked_ver> <staged_manifest_content|MISSING> <expect_ver|any_baked>
  id="$1"; desc="$2"; bv="$3"; sm="$4"; want="$5"
  rm -rf "$WORK/vg"; mkdir -p "$WORK/vg/src/greenautarky_site" "$WORK/vg/addons/data/99f1cad4_ga_manager/ga-custom-components/greenautarky_site"
  printf '{"domain":"greenautarky_site","version":"%s"}\n' "$bv" > "$WORK/vg/src/greenautarky_site/manifest.json"
  printf 'baked\n' > "$WORK/vg/src/greenautarky_site/__init__.py"
  vd="$WORK/vg/addons/data/99f1cad4_ga_manager/ga-custom-components/greenautarky_site"
  printf 'staged\n' > "$vd/__init__.py"
  if [ "$sm" = MISSING ]; then rm -f "$vd/manifest.json"; else printf '%s\n' "$sm" > "$vd/manifest.json"; fi
  GA_STAGE_SRC="$WORK/vg/src" GA_STAGE_SHARE_DST="$WORK/vg/share" \
    GA_STAGE_PRIV_GLOB="$WORK/vg/addons/data/*_ga_manager" sh "$STAGE" >"$WORK/vg/out" 2>&1
  if [ "$want" = baked ]; then
    run_test "$id" "$desc" "grep -q '^baked\$' '$vd/__init__.py'"
  else
    run_test "$id" "$desc" "grep -q '^staged\$' '$vd/__init__.py'"
  fi
}
vg_case GSV-50 "staged newer is KEPT over baked (2.12.12 > 2.12.6)" 2.12.6 '{"version":"2.12.12"}' staged
vg_case GSV-51 "numeric not lexical: staged 2.12.12 KEPT over baked 2.12.9" 2.12.9 '{"version":"2.12.12"}' staged
vg_case GSV-52 "numeric not lexical: baked 2.12.12 RESTAGED over staged 2.12.9" 2.12.12 '{"version":"2.12.9"}' baked
vg_case GSV-53 "baked newer is restaged" 2.12.9 '{"version":"2.12.6"}' baked
vg_case GSV-54 "equal version is kept (no rewrite)" 2.12.9 '{"version":"2.12.9"}' staged
vg_case GSV-55 "staged manifest missing -> restaged from baked" 2.12.9 MISSING baked
vg_case GSV-56 "staged manifest has no version -> restaged" 2.12.9 '{"domain":"x"}' baked
vg_case GSV-57 "staged manifest garbage -> restaged" 2.12.9 'not json {{{' baked
vg_case GSV-58 "staged version non-numeric -> restaged" 2.12.9 '{"version":"latest"}' baked
vg_case GSV-59 "CAP: staged 2.13 (higher minor) RESTAGED over baked 2.12.9" 2.12.9 '{"version":"2.13"}' baked
vg_case GSV-62 "CAP: staged 2.13.0 RESTAGED over baked 2.12.9" 2.12.9 '{"version":"2.13.0"}' baked
vg_case GSV-63 "CAP: staged 3.0.0 RESTAGED over baked 2.12.9" 2.12.9 '{"version":"3.0.0"}' baked
vg_case GSV-64 "CAP: staged 99.0.0 RESTAGED over baked 2.12.9" 2.12.9 '{"version":"99.0.0"}' baked
vg_case GSV-65 "OVERFLOW: 99999999999999999999.0.0 unparsable -> RESTAGED" 2.12.9 '{"version":"99999999999999999999.0.0"}' baked
vg_case GSV-66 "OVERFLOW: 10-digit component unparsable -> RESTAGED" 2.12.9 '{"version":"2.12.1234567890"}' baked
vg_case GSV-67 "SUFFIX: staged 2.12.12-rc1 RESTAGED (baked wins)" 2.12.9 '{"version":"2.12.12-rc1"}' baked
vg_case GSV-68 "SUFFIX: staged 2.12.9+x at same core RESTAGED" 2.12.9 '{"version":"2.12.9+x"}' baked
vg_case GSV-69 "non-numeric part 2.12.x unparsable -> RESTAGED" 2.12.9 '{"version":"2.12.x"}' baked
vg_case GSV-70 "2.12 vs baked 2.12.0 is equal -> KEPT" 2.12.0 '{"version":"2.12"}' staged
vg_case GSV-71 "patch-only newer 2.12.10 KEPT over baked 2.12.9" 2.12.9 '{"version":"2.12.10"}' staged
run_test "GSV-60" "keep is logged at INFO (newer staged)" \
  "{ printf '{\"version\":\"2.12.12\"}\n' > '$vd/manifest.json'; GA_STAGE_SRC='$WORK/vg/src' GA_STAGE_SHARE_DST='$WORK/vg/share' GA_STAGE_PRIV_GLOB='$WORK/vg/addons/data/*_ga_manager' sh '$STAGE' 2>&1 | grep -q 'INFO trusted: keeping newer staged greenautarky_site 2.12.12 over baked 2.12.9'; }"
# /share compat stays strict: forged HIGHER version is repaired, not kept.
run_test "GSV-61" "compat /share: forged higher version is still restaged" \
  "printf '{\"version\":\"99.0.0\"}\n' > '$WORK/vg/share/greenautarky_site/manifest.json' && printf 'evil\n' > '$WORK/vg/share/greenautarky_site/__init__.py' && GA_STAGE_SRC='$WORK/vg/src' GA_STAGE_SHARE_DST='$WORK/vg/share' GA_STAGE_PRIV_GLOB='$WORK/vg/addons/data/*_ga_manager' sh '$STAGE' >/dev/null 2>&1; grep -q '^baked\$' '$WORK/vg/share/greenautarky_site/__init__.py'"

rm -rf "$WORK"
suite_end
