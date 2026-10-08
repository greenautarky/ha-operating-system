#!/usr/bin/env bash
# os_version_order/selftest.sh — every helper in this repo that orders OS
# versions, or picks an image by its version, puts 16.3.1.10 ABOVE 16.3.1.9.
#
# WHY
#   From BOSv1.5.0-rc2 VERSION_SUFFIX is "1.10", so the OS version is 16.3.1.10.
#   Every 1.3.x and 1.4.x image shipped as 16.3.1.9, so this is the first
#   two-digit last field. A plain `sort`, a string `<` or a float reading of
#   the suffix (1.10 < 1.9) orders it BELOW 16.3.1.9. Before this change
#   scripts/create-release.sh picked "the latest image" with `ls | sort | tail -1`,
#   which is exactly that.
#
# WHAT RUNS
#   The LIVE definitions, never a copy:
#     scripts/lib/os-version.sh    os_version_cmp, newest_bos_image (sourced)
#     scripts/ga_build.sh          get_original_image_basename (extracted by name)
#   Fixture pairs (both orders where they differ):
#     16.3.1.9  vs 16.3.1.10   -> older
#     16.3.1.10 vs 16.3.2      -> older
#     16.3.1.10 vs 16.3.1.10   -> equal
#
# RED PROOF (part of this test, not a paste)
#   The same fixture is run against three mutants built from the live helpers:
#   a lexical os_version_cmp, a float os_version_cmp, and the pre-change
#   `sort | tail -1` image picker, plus a get_original_image_basename that takes
#   the first haos_* image by name. Each mutant MUST fail, and must fail on the
#   16.3.1.9-vs-16.3.1.10 case specifically — a mutant caught only by some other
#   case would leave the guard for THIS case unproven.
#
# Exit 0 = live helpers green AND every mutant red. Anything else exits 1;
# a helper that cannot be found exits 2 (could not check is never green).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$ROOT/scripts/lib/os-version.sh"
GA_BUILD="$ROOT/scripts/ga_build.sh"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

[ -f "$LIB" ] || { echo "ERROR: $LIB not found" >&2; exit 2; }
[ -f "$GA_BUILD" ] || { echo "ERROR: $GA_BUILD not found" >&2; exit 2; }

# --- extract get_original_image_basename from the live ga_build.sh ---------
awk '/^get_original_image_basename\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' "$GA_BUILD" > "$W/gaob.sh"
grep -q '^get_original_image_basename() {$' "$W/gaob.sh" && grep -q '^}$' "$W/gaob.sh" \
  || { echo "ERROR: could not extract get_original_image_basename from $GA_BUILD" >&2; exit 2; }

# fixture LIB GAOB SHELL — runs every case, prints "ok|FAIL <id> ...", and
# exits with the number of failed cases.
fixture() {
  "$3" -c '
    LIB="$1"; GAOB="$2"; W="$3"
    . "$LIB"
    n=0
    ok()  { echo "ok    $1"; }
    bad() { echo "FAIL  $1 (got: $2)"; n=$((n + 1)); }
    for f in os_version_cmp newest_bos_image; do
      command -v "$f" >/dev/null 2>&1 || { echo "FAIL  $f not defined by $LIB"; exit 99; }
    done

    cmp() {  # id a b want
      got="$(os_version_cmp "$2" "$3")"; rc=$?
      if [ "$rc" = 0 ] && [ "$got" = "$4" ]; then ok "$1"; else bad "$1" "rc=$rc out=$got want=$4"; fi
    }
    cmp CMP-1.9-lt-1.10       16.3.1.9  16.3.1.10 -1
    cmp CMP-1.10-gt-1.9       16.3.1.10 16.3.1.9   1
    cmp CMP-1.10-lt-16.3.2    16.3.1.10 16.3.2    -1
    cmp CMP-16.3.2-gt-1.10    16.3.2    16.3.1.10  1
    cmp CMP-1.10-eq-1.10      16.3.1.10 16.3.1.10  0
    cmp CMP-missing-field-eq  16.3.1    16.3.1.0   0
    for m in "" 16 16.3.x 16..3 .16.3 16.3. "16.3 1"; do
      got="$(os_version_cmp "$m" 16.3.1.9)"; rc=$?
      if [ "$rc" = 2 ] && [ -z "$got" ]; then ok "CMP-malformed[$m]"; else bad "CMP-malformed[$m]" "rc=$rc out=$got"; fi
    done

    pick() {  # id want file...
      id="$1"; want="$2"; shift 2
      got="$(newest_bos_image "$@")"
      if [ "$got" = "$want" ]; then ok "$id"; else bad "$id" "$got want=$want"; fi
    }
    I=/x/images
    # Higher version wins even when its build is OLDER — version first.
    pick PICK-1.9-vs-1.10 "$I/bos_ihost-16.3.1.10_prod_20261001000000.img.xz" \
      "$I/bos_ihost-16.3.1.9_prod_20261008120000.img.xz" \
      "$I/bos_ihost-16.3.1.10_prod_20261001000000.img.xz"
    pick PICK-1.10-vs-16.3.2 "$I/bos_ihost-16.3.2_prod_20261001000000.img.xz" \
      "$I/bos_ihost-16.3.2_prod_20261001000000.img.xz" \
      "$I/bos_ihost-16.3.1.10_prod_20261008120000.img.xz"
    # Same version: the newer build; the provisioning image is never the release image.
    pick PICK-1.10-eq-1.10 "$I/bos_ihost-16.3.1.10_prod_20261008120000.img.xz" \
      "$I/bos_ihost-16.3.1.10_prod_20261001000000.img.xz" \
      "$I/bos_ihost-16.3.1.10_prod_20261008120000.img.xz" \
      "$I/bos_ihost-16.3.1.10_prod_20261008120000_provisioning.img.xz"
    if newest_bos_image "$I/notes.txt" "$I/bos_ihost-16.3.1.10_prod_2026.img.xz" >/dev/null; then
      bad PICK-nothing-qualifies "returned 0"; else ok PICK-nothing-qualifies; fi

    exit "$n"
  ' fixture "$1" "$2" "$W" || return $?
}

# fixture for get_original_image_basename (bash: the function is bash).
gaob_fixture() {
  bash -c '
    GAOB="$1"; W="$2"
    . "$GAOB"
    n=0
    ok()  { echo "ok    $1"; }
    bad() { echo "FAIL  $1 (got: $2)"; n=$((n + 1)); }
    case_() {  # id suffix want files...
      id="$1"; suf="$2"; want="$3"; shift 3
      d="$W/$id"; rm -rf "$d"; mkdir -p "$d/ext" "$d/out/images"
      printf "VERSION_MAJOR=\"16\"\nVERSION_MINOR=\"3\"\nVERSION_SUFFIX=\"%s\"\n" "$suf" > "$d/ext/meta"
      for f in "$@"; do : > "$d/out/images/$f"; done
      got="$(BR2EXT_NETBIRD="$d/ext" OUT="$d/out" get_original_image_basename 2>/dev/null)"; rc=$?
      got="${got#"$d/out/images/"}"
      if [ "$want" = FAIL ]; then
        if [ "$rc" != 0 ]; then ok "$id"; else bad "$id" "rc=0 out=$got want=failure"; fi
      elif [ "$rc" = 0 ] && [ "$got" = "$want" ]; then ok "$id"; else bad "$id" "rc=$rc out=$got want=$want"; fi
    }
    case_ GAOB-1.10-beside-stale-1.9 1.10 haos_ihost-16.3.1.10 haos_ihost-16.3.1.9.img.xz haos_ihost-16.3.1.10.img.xz
    case_ GAOB-1.9-beside-stale-1.10 1.9  haos_ihost-16.3.1.9  haos_ihost-16.3.1.10.img.xz haos_ihost-16.3.1.9.img.xz
    case_ GAOB-only-stale-1.9        1.10 FAIL                 haos_ihost-16.3.1.9.img.xz
    case_ GAOB-1.10-uncompressed     1.10 haos_ihost-16.3.1.10 haos_ihost-16.3.1.10.img
    exit "$n"
  ' gaob "$1" "$W" || return $?
}

status=0

# --- 1. GREEN: the live helpers -------------------------------------------
for sh in bash sh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  echo "== live helpers under $sh"
  out="$(fixture "$LIB" "$W/gaob.sh" "$sh")"; rc=$?
  echo "$out" | sed 's/^/  /'
  n_ok="$(printf '%s\n' "$out" | grep -c '^ok ')"
  if [ "$rc" != 0 ]; then echo "  -> RED: $rc case(s) failed"; status=1
  elif [ "$n_ok" -lt 16 ]; then echo "  -> RED: only $n_ok cases ran — coverage collapsed"; status=1
  else echo "  -> green ($n_ok cases)"; fi
done
echo "== live get_original_image_basename (scripts/ga_build.sh)"
out="$(gaob_fixture "$W/gaob.sh")"; rc=$?
echo "$out" | sed 's/^/  /'
if [ "$rc" != 0 ] || [ "$(printf '%s\n' "$out" | grep -c '^ok ')" -ne 4 ]; then
  echo "  -> RED"; status=1; else echo "  -> green (4 cases)"; fi

# --- 1b. Reachability: the release packager actually uses the helper ------
# A correct helper nobody calls fixes nothing. create-release.sh must source
# the lib and pick its image with newest_bos_image, not with a sort.
CR="$ROOT/scripts/create-release.sh"
echo "== scripts/create-release.sh picks its image through newest_bos_image"
if grep -Eq '^\. "\$\{SCRIPT_DIR\}/lib/os-version\.sh"$' "$CR" \
   && grep -Eq '^IMG_XZ="\$\(newest_bos_image ' "$CR" \
   && ! grep -Eq '^IMG_XZ=.*\| *sort' "$CR"; then
  echo "  -> green"
else
  echo "  -> RED: create-release.sh does not select IMG_XZ via newest_bos_image"; status=1
fi

# --- 2. RED: mutants of the live helpers must fail the same fixture --------
# Each mutant = the live lib + one overriding definition appended, so the
# rest of the lib (newest_bos_image calls os_version_cmp) is the real code.
mutant() {  # name body
  cp "$LIB" "$W/mut-$1.sh"
  printf '\n%s\n' "$2" >> "$W/mut-$1.sh"
}
mutant lexical 'os_version_cmp() {
	os_version_valid "$1" && os_version_valid "$2" || return 2
	if [ "$1" = "$2" ]; then echo 0
	elif [ "$(printf "%s\n%s\n" "$1" "$2" | LC_ALL=C sort | head -n 1)" = "$1" ]; then echo -1
	else echo 1; fi
}'
mutant float 'os_version_cmp() {
	os_version_valid "$1" && os_version_valid "$2" || return 2
	# MAJOR.MINOR, then the suffix read as a decimal number ("1.10" -> 1.1).
	awk -v a="$1" -v b="$2" '"'"'BEGIN {
		na = split(a, x, "."); nb = split(b, y, ".")
		ma = (x[1] "." x[2]) + 0; mb = (y[1] "." y[2]) + 0
		sa = (x[3] "." (na > 3 ? x[4] : 0)) + 0; sb = (y[3] "." (nb > 3 ? y[4] : 0)) + 0
		if (ma != mb) { print (ma < mb ? -1 : 1); exit }
		if (sa != sb) { print (sa < sb ? -1 : 1); exit }
		print 0 }'"'"'
}'
mutant sort-tail 'newest_bos_image() {
	# the picker scripts/create-release.sh used before this change
	printf "%s\n" "$@" | sort | tail -n 1
}'

for m in lexical float sort-tail; do
  echo "== mutant: $m (must go red on the 16.3.1.9 vs 16.3.1.10 case)"
  out="$(fixture "$W/mut-$m.sh" "$W/gaob.sh" bash)"; rc=$?
  printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/  /'
  case "$m" in
    sort-tail) key='^FAIL  PICK-1\.9-vs-1\.10 ' ;;
    *)         key='^FAIL  (CMP-1\.9-lt-1\.10|CMP-1\.10-gt-1\.9) ' ;;
  esac
  if [ "$rc" = 0 ]; then
    echo "  -> PROBLEM: the fixture passed a $m helper — it cannot tell 16.3.1.10 from 16.3.1.9"; status=1
  elif ! printf '%s\n' "$out" | grep -Eq "$key"; then
    echo "  -> PROBLEM: red, but not on the 16.3.1.9 vs 16.3.1.10 case"; status=1
  else
    echo "  -> red as required ($rc case(s))"
  fi
done

# The image-basename picker before this change: first haos_* by name.
cat > "$W/gaob-mut.sh" <<'EOF'
get_original_image_basename() {
  local img
  img="$(ls "${OUT}/images/"haos_*.img.xz "${OUT}/images/"haos_*.img 2>/dev/null | head -n 1 || true)"
  [[ -n "$img" ]] || return 1
  img="${img%.xz}"; img="${img%.img}"; echo "$img"
}
EOF
echo "== mutant: get_original_image_basename takes the first haos_* by name"
out="$(gaob_fixture "$W/gaob-mut.sh")"; rc=$?
printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/  /'
if [ "$rc" = 0 ]; then echo "  -> PROBLEM: the fixture passed it"; status=1
elif ! printf '%s\n' "$out" | grep -Eq '^FAIL  GAOB-(1\.9-beside-stale-1\.10|only-stale-1\.9) '; then
  echo "  -> PROBLEM: red, but not on a mixed-version case"; status=1
else echo "  -> red as required ($rc case(s))"; fi

echo
if [ "$status" = 0 ]; then echo "os_version_order: PASS — live helpers green, every mutant red"
else echo "os_version_order: FAIL"; fi
exit "$status"
