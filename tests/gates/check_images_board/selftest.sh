#!/bin/bash
# check_images_board -- the pre-flight image check (scripts/check-images.sh, run by ga_build.sh before the
# multi-hour build) reads THE BOARD's own add-on pin file, arch and machine. Odoo #1617: it always read the
# iHost's pin file with armv7, so the ga_default_addon-aarch64 image that was missing in a DSGW-210 bake
# (50 builder minutes) and a pin file out of lockstep with the store were both invisible to it.
#
# Drives the LIVE script on this checkout (its real defconfigs, tree-paths and pin files); only the registry
# (skopeo) and the store (a git repo built from the pins under test) are stand-ins. The stub records every
# image it is asked about, so "which arch was asked" is read from what the check did, not from what it said.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../../../scripts/lib/tree-paths.sh
. "$ROOT/scripts/lib/tree-paths.sh"
for t in jq git; do command -v "$t" >/dev/null || { echo "FATAL: $t missing"; exit 2; }; done
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0; ran=0
ok()  { ran=$((ran+1)); echo "  ok    $1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); echo "  FAIL  $1"; }
mkdir -p "$W/bin"
cat > "$W/bin/skopeo" <<'SK'
#!/bin/bash
# inspect: record "<ref> <platform flags>", succeed. list-tags: print the tag the ref carries in $STUB_NEWEST.
case "$1" in
  inspect) echo "${*: -1} :: $*" >> "$STUB_LOG"; exit 0 ;;
  list-tags) ref="${2#docker://}"; printf '{"Tags":["%s"]}\n' "$(cat "$STUB_NEWEST/$(basename "${ref%%:*}")" 2>/dev/null || echo 0.0.1)" ;;
  *) exit 0 ;;
esac
SK
chmod +x "$W/bin/skopeo"
cat > "$W/chan.json" <<'J'
{"supervisor":"1","core":"1","cli":"1","dns":"1","audio":"1","multicast":"1","observer":"1",
 "images":{"supervisor":"example.invalid/{arch}-sup","core":"example.invalid/core-{arch}-{machine}",
 "cli":"example.invalid/{arch}-cli","dns":"example.invalid/{arch}-dns","audio":"example.invalid/{arch}-audio",
 "multicast":"example.invalid/{arch}-mc","observer":"example.invalid/{arch}-obs"}}
J
# a store that is in lockstep with <pins file> (or with <pins file> but one version replaced)
mkstore() {  # <pins> <addon key to skew or ""> <skewed version>
  rm -rf "$W/store"; mkdir -p "$W/store"
  local k img v d
  for k in $(jq -r '.addons|keys[]' "$1"); do
    img="$(jq -r ".addons.\"$k\".image" "$1")"; v="$(jq -r ".addons.\"$k\".version" "$1")"
    [ "$k" = "${2:-}" ] && v="$3"
    d="$W/store/$k"; mkdir -p "$d"; printf 'name: "%s"\nversion: "%s"\nslug: "%s"\nimage: %s\n' "$k" "$v" "$k" "$img" > "$d/config.yaml"
  done
  git -C "$W/store" init -q -b main; git -C "$W/store" -c user.email=t@e -c user.name=t add -A; git -C "$W/store" -c user.email=t@e -c user.name=t commit -qm s
}
run() {  # <board or ""> <script> [more env...] -> stdout+stderr; rc in $RC; asked refs in $W/asked
  local b="$1" sc="$2"; shift 2
  : > "$W/asked"
  env ${b:+GA_BOARD="$b"} PATH="$W/bin:$PATH" STUB_LOG="$W/asked" STUB_NEWEST="$W/newest" REPO_ROOT="$ROOT" \
      VIBE_ADDONS_REPO_URL="$W/store" VIBE_ADDONS_REPO_REF=main GA_SOURCE_DRIFT_STRICT=1 "$@" \
      bash "$sc" "$W/chan.json" > "$W/out" 2>&1
  RC=$?
}
mkdir -p "$W/newest"
for b in $GA_BOARDS; do
  pins="$ROOT/$(ga_board_var ADDON_PINS "$b")"
  arch="$(sed -n 's/^BR2_PACKAGE_HASSIO_ARCH="\(.*\)"$/\1/p' "$ROOT/$(ga_board_var DEFCONFIG "$b")")"
  other="armv7"; [ "$arch" = armv7 ] && other="aarch64"
  rm -rf "$W/newest"; mkdir -p "$W/newest"
  for k in $(jq -r '.addons|keys[]' "$pins"); do jq -r ".addons.\"$k\".version" "$pins" > "$W/newest/$(jq -r ".addons.\"$k\".image" "$pins" | sed 's|.*/||; s|{arch}|'"$arch"'|')"; done
  mkstore "$pins" "" ""
  run "$b" "$ROOT/scripts/check-images.sh"; out="$(cat "$W/out")"
  # every pin of THIS board's file was asked for, with THIS board's arch -- and no other arch
  want="$(jq -r '.addons|to_entries[]|.value.image+":"+.value.version' "$pins" | sed "s|{arch}|$arch|" | sort)"
  got="$(grep -oE 'ghcr\.io/greenautarky/[^ ]+:[^ ]+' "$W/asked" | grep -vE 'example.invalid' | sed 's/ .*//' | sort -u)"
  missing="$(comm -23 <(echo "$want") <(echo "$got") | tr '\n' ' ')"
  [ -z "$missing" ] && ok "$b: every pin of ITS file was checked as $arch ($(echo "$want" | wc -l) images)" || bad "$b: pins not asked for as $arch: $missing"
  grep -qE -- "-${other}[: ]" "$W/asked" && bad "$b: an $other image was asked for" || ok "$b: no $other image was asked for"
  [ "$RC" = 0 ] && ok "$b: the pre-flight passes on its own, in-lockstep pins" || { bad "$b: rc=$RC"; echo "$out" | tail -n 5 | sed 's/^/          /'; }
  grep -q "Board: $b  arch: $arch" <<<"$out" && ok "$b: the check states board and arch" || bad "$b: no 'Board: $b  arch: $arch' line"
  # out of lockstep with the store (the #1617 state) -> red, naming the add-on
  k1="$(jq -r '.addons|to_entries[]|select(.value.store_ahead|not)|.key' "$pins" | head -n 1)"
  mkstore "$pins" "$k1" "0.0.0"
  run "$b" "$ROOT/scripts/check-images.sh"; out="$(cat "$W/out")"
  { [ "$RC" != 0 ] && grep -q "FAIL.*$k1 version mismatch" <<<"$out"; } && ok "$b: a pin out of lockstep with the store fails the pre-flight ($k1)" || bad "$b: store skew on $k1 not caught (rc=$RC)"
done
run nosuchboard "$ROOT/scripts/check-images.sh"; out="$(cat "$W/out")"
{ [ "$RC" != 0 ] && grep -q "unknown board" <<<"$out"; } && ok "an unknown board is an error, not the iHost" || bad "unknown board accepted (rc=$RC)"

# ---- store_ahead: a pin AHEAD of the store may be declared; nothing else is excused ----------------------
# The real DSGW file against a store that is on the iHost's versions (the 2026-11-06 state of #1617).
pins="$ROOT/$(ga_board_var ADDON_PINS dsgw210)"
rm -rf "$W/newest"; mkdir -p "$W/newest"
mkstore "$pins" "" ""
for k in ga_default_addon ga_hmvapp_addon; do
  sed -i "s/^version: .*/version: \"$(jq -r ".addons.$k.version" "$ROOT/$(ga_board_var ADDON_PINS ihost)")\"/" "$W/store/$k/config.yaml"
done
git -C "$W/store" -c user.email=t@e -c user.name=t commit -qam skew
for k in ga_default_addon ga_hmvapp_addon; do jq -r ".addons.$k.version" "$pins" > "$W/newest/$(jq -r ".addons.$k.image" "$pins" | sed 's|.*/||; s|{arch}|aarch64|')"; done
for k in $(jq -r '.addons|keys[]' "$pins"); do [ -s "$W/newest/$(jq -r ".addons.\"$k\".image" "$pins" | sed 's|.*/||; s|{arch}|aarch64|')" ] || jq -r ".addons.\"$k\".version" "$pins" > "$W/newest/$(jq -r ".addons.\"$k\".image" "$pins" | sed 's|.*/||; s|{arch}|aarch64|')"; done
run dsgw210 "$ROOT/scripts/check-images.sh"
{ [ "$RC" = 0 ] && [ "$(grep -c AHEAD-OF-STORE "$W/out")" = 2 ]; } && ok "dsgw210: the real file vs a store on the iHost's versions passes, loudly (2 x AHEAD-OF-STORE)" || { bad "dsgw210 real file vs old store: rc=$RC"; grep -E 'FAIL|AHEAD|INVALID' "$W/out" | sed 's/^/          /'; }
# scratch tree for the declaration rules
mkdir -p "$W/r/buildroot-dsgw210/configs"; cp "$ROOT/$(ga_board_var DEFCONFIG dsgw210)" "$W/r/buildroot-dsgw210/configs/"
decl() {  # <label> <declaration json or ""> <pinned> <store> <expect-rc> <regex>
  jq -n --arg v "$3" --argjson d "${2:-null}" '{addons:{ga_default_addon:({image:"ghcr.io/greenautarky/ga_default_addon-{arch}",version:$v}+(if $d then {store_ahead:$d} else {} end))}}' > "$W/r/buildroot-dsgw210/addon-images.json"
  rm -rf "$W/store"; mkdir -p "$W/store/ga_default_addon"
  printf 'name: x\nversion: "%s"\nslug: ga_default_addon\nimage: ghcr.io/greenautarky/ga_default_addon-{arch}\n' "$4" > "$W/store/ga_default_addon/config.yaml"
  git -C "$W/store" init -q -b main; git -C "$W/store" -c user.email=t@e -c user.name=t add -A; git -C "$W/store" -c user.email=t@e -c user.name=t commit -qm s
  rm -rf "$W/newest"; mkdir -p "$W/newest"; echo "$3" > "$W/newest/ga_default_addon-aarch64"
  run dsgw210 "$ROOT/scripts/check-images.sh" REPO_ROOT="$W/r" GA_TODAY=2026-11-06
  if [ "$RC" = "$5" ] && grep -qE "$6" "$W/out"; then ok "store_ahead: $1"; else bad "store_ahead: $1 (rc=$RC, want $5, /$6/)"; grep -E 'FAIL|AHEAD|INVALID' "$W/out" | sed 's/^/          /'; fi
}
decl "valid declaration, pin newer than the store -> passes"      '{"reason":"r","until":"2026-12-04"}' 2.1.7 2.1.6 0 'AHEAD-OF-STORE'
decl "no declaration, pin newer than the store -> lockstep FAIL"   '' 2.1.7 2.1.6 1 'FAIL.*version mismatch'
decl "declaration without a reason -> invalid, FAIL"               '{"until":"2026-12-04"}' 2.1.7 2.1.6 1 'STORE_AHEAD INVALID.*no reason'
decl "expired declaration -> invalid, FAIL"                        '{"reason":"r","until":"2026-11-05"}' 2.1.7 2.1.6 1 'STORE_AHEAD INVALID.*expired'
decl "open-ended declaration (> 30 days) -> invalid, FAIL"         '{"reason":"r","until":"2027-01-01"}' 2.1.7 2.1.6 1 'STORE_AHEAD INVALID.*more than 30 days'
decl "malformed date -> invalid, FAIL"                             '{"reason":"r","until":"soon"}' 2.1.7 2.1.6 1 'STORE_AHEAD INVALID.*not YYYY-MM-DD'
decl "declared, but the pin is BEHIND the store -> still FAIL"     '{"reason":"r","until":"2026-12-04"}' 2.1.6 2.1.7 1 'STORE_AHEAD INVALID.*not newer'

# ---- no derivable channel file (the check-versions workflow runs this bare, without the haos submodule) ----
# The iHost keeps the legacy URL - loudly, and the script must not die silently before saying anything;
# any other board is an error.
mkdir -p "$W/nohaos/lib"; cp "$ROOT/scripts/lib/tree-paths.sh" "$W/nohaos/lib/"; cp "$ROOT/scripts/check-images.sh" "$W/nohaos/"
printf '#!/bin/sh\nexit 1\n' > "$W/nohaos/apply-haos-patches.sh"; chmod +x "$W/nohaos/apply-haos-patches.sh"
cat > "$W/bin/curl" <<'CU'
#!/bin/bash
echo "$*" >> "$STUB_LOG"; exit 22
CU
chmod +x "$W/bin/curl"
: > "$W/asked"
env PATH="$W/bin:$PATH" STUB_LOG="$W/asked" REPO_ROOT="$ROOT" bash "$W/nohaos/check-images.sh" > "$W/out" 2>&1; RC=$?
{ grep -q "NOTE: could not derive the ihost channel file" "$W/out" && grep -q "haos-version/main/stable.json" "$W/asked"; } \
  && ok "iHost, channel file not derivable: loud NOTE and the legacy URL (not a silent exit; rc=$RC)" || { bad "iHost without haos: no NOTE / no legacy URL (rc=$RC)"; tail -n 4 "$W/out" | sed 's/^/          /'; }
env GA_BOARD=dsgw210 PATH="$W/bin:$PATH" STUB_LOG="$W/asked" REPO_ROOT="$ROOT" bash "$W/nohaos/check-images.sh" > "$W/out" 2>&1; RC=$?
{ [ "$RC" != 0 ] && grep -q "cannot derive its channel file" "$W/out"; } && ok "dsgw210, channel file not derivable: error naming the cause" || bad "dsgw210 without haos: rc=$RC"
rm -f "$W/bin/curl"

# ---- red proof: the pre-change script (iHost pin file + armv7 whatever the board) --------------------
mkdir -p "$W/old/lib"; cp "$ROOT/scripts/lib/tree-paths.sh" "$W/old/lib/"
cp "$ROOT/scripts/check-images.sh" "$W/old/check-images.sh"
perl -0pi -e 's/BOARD="\$\{GA_BOARD:-ihost\}"/BOARD=ihost/; s/ARCH="\$\{CHECK_ARCH:-\$\(_dc_var BR2_PACKAGE_HASSIO_ARCH\)\}"/ARCH=armv7/; s/MACHINE="\$\{CHECK_MACHINE:-\$\(_dc_var BR2_PACKAGE_HASSIO_MACHINE\)\}"/MACHINE=tinker/' "$W/old/check-images.sh"
cmp -s "$ROOT/scripts/check-images.sh" "$W/old/check-images.sh" && bad "red proof: the pre-change mutation changed nothing"
pins="$ROOT/$(ga_board_var ADDON_PINS dsgw210)"; mkstore "$pins" "" ""; : > "$W/asked"
rm -rf "$W/newest"; mkdir -p "$W/newest"
run dsgw210 "$W/old/check-images.sh"
grep -qE -- "-armv7[: ]" "$W/asked" && ok "red proof: the pre-change check asks a DSGW bake for armv7 images (the #1617 defect)" || bad "red proof: pre-change script did not reproduce the defect"

[ "$ran" -ge 22 ] || { echo "FAIL: only $ran cases ran"; exit 1; }
echo "$ran cases ran, $fails failed"; exit $((fails>0))
