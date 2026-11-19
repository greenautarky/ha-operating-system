#!/usr/bin/env bash
# ga_release_naming/selftest.sh - ADR-0055: artifacts and displays are named after the
# ga_release, the technical identifiers are NOT touched.
#
# WHAT RUNS (the LIVE definitions, never a copy):
#   scripts/lib/ga-release-label.sh        label / name / stamper (sourced)
#   scripts/ga_build.sh                    rename_images_with_build_id + get_original_image_basename
#                                          (extracted by name; not found = exit 2, never skip)
#   scripts/lib/release-gate.sh            ga_gate_needs_vccio5 (file-name driven)
#   scripts/push-ota.sh                    version-from-filename fallback (extracted)
#   patches-haos/0114 via apply-haos-patches.sh --cat  the RAUC manifest template
# FIXTURES: names and targets the gate lets through (must-pass), and what it has to refuse (must-fail)
#   (legacy bos_*_prod_<ts> names, the OTA store name haos_<board>-<ver>.raucb, a stamper that
#   replaced the os-release symlink, one that moved VERSION_ID/CPE_NAME ...).
# RED PROOF (part of the test): five mutants of the live code, each must go red on the SPECIFIC
#   case that guards it.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$ROOT/scripts/lib/ga-release-label.sh"
GAB="$ROOT/scripts/ga_build.sh"
RG="$ROOT/scripts/lib/release-gate.sh"
PUSH="$ROOT/scripts/push-ota.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
for f in "$LIB" "$GAB" "$RG" "$PUSH"; do [ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 2; }; done

# --- extraction: fail (2), never skip, when the live definition is not found -----------------
awk '/^get_original_image_basename\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' "$GAB" > "$W/gaob.sh"
awk '/^rename_images_with_build_id\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' "$GAB" > "$W/rename.sh"
for fn in get_original_image_basename rename_images_with_build_id; do
  f="$W/gaob.sh"; [ "$fn" = rename_images_with_build_id ] && f="$W/rename.sh"
  grep -q "^${fn}() {\$" "$f" && grep -q '^}$' "$f" || { echo "ERROR: could not extract $fn from $GAB" >&2; exit 2; }
done
sed -n '/New name: the OS version is the LAST/,/grep -oP/p' "$PUSH" | grep -v '^[[:space:]]*#' > "$W/push-ver.sh"
grep -q 'sed -nE' "$W/push-ver.sh" && grep -q 'grep -oP' "$W/push-ver.sh" || { echo "ERROR: could not extract the version-from-filename step of push-ota.sh" >&2; exit 2; }
# shellcheck disable=SC1090
[ -d "$ROOT/haos/buildroot-external" ] || { echo "ERROR: haos submodule not checked out (git submodule update --init --depth 1 haos)" >&2; exit 2; }
bash "$ROOT/scripts/apply-haos-patches.sh" --cat buildroot-external/ota/manifest.raucm.gtpl > "$W/manifest.gtpl" 2>"$W/cat.err" \
  || { echo "ERROR: cannot extract the patched manifest template: $(cat "$W/cat.err")" >&2; exit 2; }

# --- the case runner (one bash per lib variant, so a mutant is the live lib + one override) ---
cases() {  # $1 = lib file; prints "ok|FAIL <id> ..."; exit = number of failures
  bash -c '
    LIB="$1"; W="$2"; ROOT="$3"
    . "$LIB"
    n=0; ok(){ echo "ok    $1"; }; bad(){ echo "FAIL  $1 ($2)"; n=$((n+1)); }
    chk(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "got [$2] want [$3]"; }

    # ---- names: must-pass round trips ----
    for t in "BOSv1.6.0-dev16 ihost 18.4.1.6" "BOSv1.6.0-rc3 ihost 18.4.1.6" "BOSv1.6.1 dsgw210 18.4.1.6" "BOSv1.6.0-dev4 dsgw210 18.4.1.10"; do
      set -- $t; b="$(ga_artifact_basename "$1" "$2" "$3")"
      chk "NAME-pass[$b]" "$b" "$1_$2_$3"
      for ext in img.xz raucb img.xz.sha256 raucb.sha256 raucb.meta.json; do
        chk "PARSE-pass[$b.$ext]" "$(ga_artifact_parse "$b.$ext")" "$1 $2 $3"
      done
    done
    chk "PARSE-pass[provisioning]" "$(ga_artifact_parse /x/BOSv1.6.0-rc3_ihost_18.4.1.6_provisioning.img.xz)" "BOSv1.6.0-rc3 ihost 18.4.1.6"
    # ---- names: must-fail ----
    for bad_ in bos_ihost-18.4.1.6_prod_20261106161119.img.xz bos_ihost-18.4.1.6_prod_20261106161119.raucb \
                haos_ihost-18.4.1.6.raucb haos_dsgw210-18.4.1.6.raucb.sha256 BOSv1.6.0_ihost.img.xz \
                BOSv1.6.0-beta1_ihost_18.4.1.6.img.xz BOSv1.6_ihost_18.4.1.6.img.xz notes.txt; do
      if ga_artifact_parse "$bad_" >/dev/null 2>&1; then bad "PARSE-fail[$bad_]" "was accepted"; else ok "PARSE-fail[$bad_]"; fi
    done
    for bl in "" BOSv1.6 v1.6.0 BOSv1.6.0-rc BOSv1.6.0-rc3-x "BOSv1.6.0 "; do
      if ga_artifact_basename "$bl" ihost 18.4.1.6 >/dev/null 2>&1; then bad "BASENAME-fail[$bl]" "was accepted"; else ok "BASENAME-fail[$bl]"; fi
    done

    # ---- stamper on a fake HAOS target ----
    mk() { d="$W/$1"; rm -rf "$d"; mkdir -p "$d/usr/lib" "$d/etc"
      cat > "$d/usr/lib/os-release" <<'"'"'EOF'"'"'
NAME="GreenAutarky BOS"
VERSION="18.4.1.6"
ID=haos
VERSION_ID="18.4.1.6"
PRETTY_NAME="GreenAutarky BOS 18.4.1.6, based on Home Assistant"
CPE_NAME="cpe:2.3:o:home-assistant:haos:18.4.1.6:*:production:*:*:*:ihost:*"
HASSOS_BOARD=ihost
GA_RELEASE="BOSv1.6.0-dev16"
EOF
      ln -s ../usr/lib/os-release "$d/etc/os-release"; echo "$d"; }
    d="$(mk s1)"; ga_stamp_release_label "$d" BOSv1.6.0-dev16; rc=$?
    chk "STAMP-rc" "$rc" 0
    chk "STAMP-pretty" "$(sed -n "s/^PRETTY_NAME=//p" "$d/usr/lib/os-release")" "\"GreenAutarky BOSv1.6.0-dev16 (HAOS 18.4.1.6)\""
    chk "STAMP-one-pretty-line" "$(grep -c "^PRETTY_NAME=" "$d/usr/lib/os-release")" 1
    [ -L "$d/etc/os-release" ] && ok "STAMP-etc-os-release-still-a-symlink" || bad "STAMP-etc-os-release-still-a-symlink" "replaced by a regular file (ga-rauc-install refuses that)"
    # every technical field is byte-identical
    for k in NAME VERSION ID VERSION_ID CPE_NAME HASSOS_BOARD GA_RELEASE; do
      want="$(mk s0 >/dev/null; sed -n "s/^${k}=//p" "$W/s0/usr/lib/os-release")"
      chk "TECH-unchanged[$k]" "$(sed -n "s/^${k}=//p" "$d/usr/lib/os-release")" "$want"
    done
    grep -qF "GreenAutarky BOSv1.6.0-dev16 (HAOS 18.4.1.6)" "$d/etc/motd" && ok "STAMP-motd" || bad "STAMP-motd" "$(cat "$d/etc/motd" 2>&1)"
    grep -qF "GreenAutarky BOSv1.6.0-dev16 (HAOS 18.4.1.6)" "$d/etc/issue" && ok "STAMP-issue" || bad "STAMP-issue" "$(cat "$d/etc/issue" 2>&1)"
    ga_stamp_release_label "$d" BOSv1.6.0-dev16 && chk "STAMP-idempotent" "$(grep -c "^PRETTY_NAME=" "$d/usr/lib/os-release")" 1
    ga_stamp_release_label "$d" BOSv1.6.0-rc3 && chk "STAMP-restamp-replaces" "$(sed -n "s/^PRETTY_NAME=//p" "$d/usr/lib/os-release")" "\"GreenAutarky BOSv1.6.0-rc3 (HAOS 18.4.1.6)\""
    # must-fail
    if ga_stamp_release_label "$W/nothing" BOSv1.6.0 2>/dev/null; then bad "STAMP-fail[no os-release]" "rc 0"; else ok "STAMP-fail[no os-release]"; fi
    if ga_stamp_release_label "$(mk s2)" "not-a-label" 2>/dev/null; then bad "STAMP-fail[bad label]" "rc 0"; else ok "STAMP-fail[bad label]"; fi
    d3="$(mk s3)"; sed -i "/^VERSION_ID=/d" "$d3/usr/lib/os-release"
    if ga_stamp_release_label "$d3" BOSv1.6.0 2>/dev/null; then bad "STAMP-fail[no VERSION_ID]" "rc 0"; else ok "STAMP-fail[no VERSION_ID]"; fi
    exit "$n"
  ' cases "$1" "$W" "$ROOT"
}

# --- live ga_build.sh rename + consumers (these do not depend on the lib variant) ----------
rename_case() {
  bash -c '
    W="$1"; ROOT="$2"; GAB="$3"
    . "$ROOT/scripts/lib/sha-sidecar.sh"; . "$W/lib.sh"
    . "$W/gaob.sh"; . "$W/rename.sh"
    n=0; ok(){ echo "ok    $1"; }; bad(){ echo "FAIL  $1 ($2)"; n=$((n+1)); }
    d="$W/r1"; rm -rf "$d"; mkdir -p "$d/ext" "$d/out/images"
    printf "VERSION_MAJOR=\"18\"\nVERSION_MINOR=\"4\"\nVERSION_SUFFIX=\"1.6\"\n" > "$d/ext/meta"
    echo img > "$d/out/images/haos_ihost-18.4.1.6.img.xz"; echo rauc > "$d/out/images/haos_ihost-18.4.1.6.raucb"
    echo stale > "$d/out/images/haos_ihost-18.4.0.1.img.xz"
    export HAOS_EXT="$d/ext" OUT="$d/out" GA_RELEASE=BOSv1.6.0-dev16 GA_BUILD_TIMESTAMP=20261119120000
    rename_images_with_build_id >/dev/null 2>&1; rc=$?
    [ "$rc" = 0 ] && ok "RENAME-rc" || bad "RENAME-rc" "$rc"
    I="$d/out/images"
    for f in BOSv1.6.0-dev16_ihost_18.4.1.6.img.xz BOSv1.6.0-dev16_ihost_18.4.1.6.raucb; do
      [ -f "$I/$f" ] && ok "RENAME-exists[$f]" || bad "RENAME-exists[$f]" "$(ls "$I")"
      ( cd "$I" && sha256sum -c --quiet "$f.sha256" >/dev/null 2>&1 ) && ok "RENAME-sidecar-verifies[$f]" || bad "RENAME-sidecar-verifies[$f]" "no/invalid sidecar"
    done
    [ "${GA_IMAGE_BASENAME:-}" = "$I/BOSv1.6.0-dev16_ihost_18.4.1.6" ] && ok "RENAME-basename-export" || bad "RENAME-basename-export" "${GA_IMAGE_BASENAME:-unset}"
    ls "$I" | grep -qE "^(bos_|.*_prod_|.*[0-9]{14})" && bad "RENAME-no-timestamp-no-prod-tag" "$(ls "$I" | tr "\n" " ")" || ok "RENAME-no-timestamp-no-prod-tag"
    # a re-bake of the same label replaces the files (loudly) instead of failing or keeping the old
    echo img2 > "$I/haos_ihost-18.4.1.6.img.xz"
    rename_images_with_build_id >/dev/null 2>"$W/rebake.err"
    [ "$(cat "$I/BOSv1.6.0-dev16_ihost_18.4.1.6.img.xz")" = img2 ] && grep -q "replacing" "$W/rebake.err" && ok "RENAME-rebake-replaces-loudly" || bad "RENAME-rebake-replaces-loudly" "$(cat "$W/rebake.err")"
    # an invalid ga_release must stop the build, not produce a half-named artefact
    echo x > "$I/haos_ihost-18.4.1.6.img.xz"
    ( GA_RELEASE="garbage" rename_images_with_build_id >/dev/null 2>&1 ) && bad "RENAME-fail[bad ga_release]" "rc 0" || ok "RENAME-fail[bad ga_release]"
    exit "$n"
  ' rename "$W" "$ROOT" "$GAB"
}

consumer_cases() {
  bash -c '
    ROOT="$1"; W="$2"
    n=0; ok(){ echo "ok    $1"; }; bad(){ echo "FAIL  $1 ($2)"; n=$((n+1)); }
    . "$ROOT/scripts/lib/release-gate.sh"
    ga_gate_needs_vccio5 BOSv1.6.1-rc2 /i/BOSv1.6.1-rc2_ihost_18.4.1.6.img.xz && ok "GATE-vccio5-needed[ihost 1.6.1]" || bad "GATE-vccio5-needed[ihost 1.6.1]" "not required"
    ga_gate_needs_vccio5 BOSv1.6.1-rc2 /i/BOSv1.6.1-rc2_dsgw210_18.4.1.6.img.xz && bad "GATE-vccio5-not-for-dsgw" "required" || ok "GATE-vccio5-not-for-dsgw"
    ga_gate_needs_vccio5 BOSv1.6.0-rc3 /i/BOSv1.6.0-rc3_ihost_18.4.1.6.img.xz && bad "GATE-vccio5-not-below-1.6.1" "required" || ok "GATE-vccio5-not-below-1.6.1"
    . "$ROOT/scripts/lib/os-version.sh"
    pick(){ id="$1"; want="$2"; shift 2; got="$(newest_bos_image "$@")"; [ "$got" = "$want" ] && ok "$id" || bad "$id" "got [$got] want [$want]"; }
    pick PICK-label-dev15-vs-dev16 /i/BOSv1.6.0-dev16_ihost_18.4.1.6.img.xz /i/BOSv1.6.0-dev15_ihost_18.4.1.6.img.xz /i/BOSv1.6.0-dev16_ihost_18.4.1.6.img.xz
    pick PICK-label-dev9-vs-dev10 /i/BOSv1.6.0-dev10_ihost_18.4.1.6.img.xz /i/BOSv1.6.0-dev10_ihost_18.4.1.6.img.xz /i/BOSv1.6.0-dev9_ihost_18.4.1.6.img.xz
    pick PICK-final-above-rc-above-dev /i/BOSv1.6.0_ihost_18.4.1.6.img.xz /i/BOSv1.6.0-rc3_ihost_18.4.1.6.img.xz /i/BOSv1.6.0_ihost_18.4.1.6.img.xz /i/BOSv1.6.0-dev16_ihost_18.4.1.6.img.xz
    pick PICK-legacy-names-ignored /i/BOSv1.6.0-dev1_ihost_18.4.1.6.img.xz /i/bos_ihost-18.4.1.9_prod_20261119000000.img.xz /i/BOSv1.6.0-dev1_ihost_18.4.1.6.img.xz
    # push-ota.sh fallback: OS version out of the file name
    ver(){ id="$1"; RAUCB="$2" bash -c "VERSION=; $(cat "$W/push-ver.sh" | sed "s/^[[:space:]]*if.*//") ; echo \"\$VERSION\"" >"$W/v.out" 2>/dev/null; got="$(tail -n 1 "$W/v.out")"; [ "$got" = "$3" ] && ok "$id" || bad "$id" "got [$got] want [$3]"; }
    ver PUSHVER-new-name /x/BOSv1.6.0-dev16_ihost_18.4.1.6.raucb 18.4.1.6
    ver PUSHVER-legacy-name /x/bos_ihost-16.3.1.10_prod_20261001000000.raucb 16.3.1.10
    # the RAUC manifest template (patches-haos/0114): description names ga_release + HAOS version; the
    # technical keys are untouched and the description carries no token push-ota.sh greps in `rauc info`
    T="$W/manifest.gtpl"
    grep -qxF "description=GreenAutarky {{ env \"ota_ga_release\" }} (HAOS {{ env \"ota_version\" }})" "$T" && ok "MANIFEST-description" || bad "MANIFEST-description" "line missing"
    grep -qxF "version={{ env \"ota_version\" }}" "$T" && grep -qxF "compatible={{ env \"ota_compatible\" }}" "$T" && ok "MANIFEST-technical-keys-unchanged" || bad "MANIFEST-technical-keys-unchanged" "version/compatible changed"
    grep -qxF "release={{ env \"ota_ga_release\" }}" "$T" && ok "MANIFEST-meta.ga-release-unchanged" || bad "MANIFEST-meta.ga-release-unchanged" "release floor input changed"
    grep "^description=" "$T" | grep -qE "Version:|Compatible:" && bad "MANIFEST-description-no-grep-token" "token present" || ok "MANIFEST-description-no-grep-token"
    # description is inside [update] (before the first following section header)
    awk "/^\\[/{s=\$0} /^description=/{print s}" "$T" | grep -qx "\\[update\\]" && ok "MANIFEST-description-in-[update]" || bad "MANIFEST-description-in-[update]" "wrong section"
    # reachability: the build calls the stamper and the packager selects by label
    grep -q "ga_stamp_release_label \"\${OUT}/target\" \"\$GA_RELEASE\"" "$ROOT/scripts/ga_build.sh" && ok "REACH-ga_build-calls-stamper" || bad "REACH-ga_build-calls-stamper" "not called"
    grep -q "newest_bos_image \"\${BUILD_DIR}/images/\"\${RELEASE_LABEL" "$ROOT/scripts/create-release.sh" && ok "REACH-create-release-selects-by-label" || bad "REACH-create-release-selects-by-label" "glob not label-bound"
    exit "$n"
  ' consumers "$ROOT" "$W"
}

cp "$LIB" "$W/lib.sh"
status=0
run() {  # title fn args... ; counts ok lines, fails on coverage collapse
  title="$1"; min="$2"; shift 2
  out="$("$@")"; rc=$?
  echo "== $title"; printf '%s\n' "$out" | sed 's/^/  /' | grep -E '^  FAIL' || true
  n_ok="$(printf '%s\n' "$out" | grep -c '^ok ')"
  if [ "$rc" != 0 ]; then echo "  -> RED ($rc case(s) failed)"; status=1
  elif [ "$n_ok" -lt "$min" ]; then echo "  -> RED: only $n_ok cases ran (want >= $min) - coverage collapsed"; status=1
  else echo "  -> green ($n_ok cases)"; fi
}
run "label lib: names + stamper (live lib)" 57 cases "$LIB"
run "ga_build.sh rename (live function)" 9 rename_case
run "consumers: release-gate, newest_bos_image, push-ota, RAUC manifest, reachability" 16 consumer_cases

# --- RED: each mutant must fail on the SPECIFIC case that guards it -------------------------
mutant() { cp "$LIB" "$W/mut-$1.sh"; printf '\n%s\n' "$2" >> "$W/mut-$1.sh"; }
expect_red() {  # mutant-name key-regex
  out="$(cases "$W/mut-$1.sh")"; rc=$?
  if [ "$rc" = 0 ]; then echo "== mutant $1 -> PROBLEM: not caught"; status=1
  elif ! printf '%s\n' "$out" | grep -Eq "^FAIL  $2"; then echo "== mutant $1 -> PROBLEM: red, but not on $2"; printf '%s\n' "$out" | grep '^FAIL' | head -3; status=1
  else echo "== mutant $1 -> red on $2 as required"; fi
}
# 1: stamper that never rewrites PRETTY_NAME
mutant nopretty 'ga_pretty_name() { printf "GreenAutarky BOS %s, based on Home Assistant\n" "$2"; }'
expect_red nopretty 'STAMP-pretty'
# 2: stamper that replaces the /etc/os-release symlink with a regular file (sed -i without --follow-symlinks)
mutant nosymlink 'ga_stamp_release_label() { local t="$1" l="$2"; sed -i "s/^PRETTY_NAME=.*/PRETTY_NAME=\"GreenAutarky $l (HAOS 18.4.1.6)\"/" "$t/etc/os-release"; mkdir -p "$t/etc"; echo "$l" > "$t/etc/motd"; echo "$l" > "$t/etc/issue"; }'
expect_red nosymlink 'STAMP-etc-os-release-still-a-symlink'
# 3: stamper that "helpfully" renames the technical identity as well
mutant techmove 'ga_stamp_release_label() { local t="$1" l="$2"; local f="$t/usr/lib/os-release"; sed -i "s/^PRETTY_NAME=.*/PRETTY_NAME=\"GreenAutarky $l (HAOS 18.4.1.6)\"/; s/^VERSION_ID=.*/VERSION_ID=\"$l\"/" "$f"; echo "GreenAutarky $l (HAOS 18.4.1.6)" > "$t/etc/motd"; echo "GreenAutarky $l (HAOS 18.4.1.6)" > "$t/etc/issue"; }'
expect_red techmove 'TECH-unchanged\[VERSION_ID\]'
# 4: parser that takes legacy names as artefact names
mutant legacyparse 'ga_artifact_parse() { [[ "${1##*/}" =~ ^(bos|BOSv)[^_]*_ ]] && echo "BOSv0.0.0 ihost 1"; }'
expect_red legacyparse 'PARSE-fail\[bos_ihost'
# 5: the live rename mutated back to the old scheme (bos_ + _prod_ + timestamp)
sed 's#new_name="$(ga_artifact_basename "$GA_RELEASE" "$board" "$osver")" || return 1#new_name="${orig_name/haos_/bos_}_prod_${GA_BUILD_TIMESTAMP}"#' "$W/rename.sh" > "$W/rename-mut.sh"
grep -q 'bos_}_prod_' "$W/rename-mut.sh" || { echo "ERROR: rename mutant did not apply (extraction drifted)" >&2; exit 2; }
cp "$W/rename.sh" "$W/rename.live"; cp "$W/rename-mut.sh" "$W/rename.sh"
out="$(rename_case)"; rc=$?; cp "$W/rename.live" "$W/rename.sh"
if [ "$rc" = 0 ]; then echo "== mutant oldscheme -> PROBLEM: not caught"; status=1
elif printf '%s\n' "$out" | grep -Eq '^FAIL  RENAME-(exists|no-timestamp-no-prod-tag)'; then echo "== mutant oldscheme -> red on RENAME-exists/no-timestamp as required"
else echo "== mutant oldscheme -> PROBLEM: red, but not on the naming cases"; status=1; fi

echo
if [ "$status" = 0 ]; then echo "ga_release_naming: PASS - live code green, every mutant red"; else echo "ga_release_naming: FAIL"; fi
exit "$status"
