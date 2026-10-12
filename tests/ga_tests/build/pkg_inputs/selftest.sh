#!/usr/bin/env bash
# Fixtures for scripts/lib/pkg-inputs.sh -- the rebuild trigger for packages
# whose patches / configure options WE carry (libglib2, xz, fluent-bit).
#
# WHAT THIS EXISTS FOR
#   Buildroot does not look at BR2_GLOBAL_PATCH_DIR or at <PKG>_CONF_OPTS again
#   once a package has its stamp files. On a reused output tree (the `update`
#   bake) a CVE patch or the minimal-fluent-bit switches would be silently
#   skipped and the bake would be green. ga_build.sh therefore fingerprints those
#   inputs and dircleans the package when they changed.
#
#   * It sources the LIVE scripts/lib/pkg-inputs.sh and stubs only `make` (what
#     the subject calls out to), recording the targets it was asked to build.
#     If a function stops being found, it FAILS (never skips).
#   * must-rebuild: no record; a patch added; a patch edited; a patch renamed;
#     the fluent-bit configure options changed -- each exactly the right package.
#   * must-not-rebuild: nothing changed since the record (every false positive
#     is a minutes-long needless rebuild per bake).
#   * mutant: a fingerprint that hashes names only must be caught by the
#     "patch edited" case.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/pkg-inputs.sh"
pass=0 fail=0
_pass() { echo "  PASS  $1"; pass=$((pass+1)); }
_fail() { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "=== pkg-inputs: rebuild trigger fixtures ==="
[ -f "$LIB" ] || { echo "  FAIL  PKGIN-00: live lib not found at $LIB"; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/pkg-inputs.XXXXXX")"
trap 'rm -rf "$W"' EXIT

# The stub: `make` records its targets; `printvars FLUENT_BIT_CONF_OPTS` answers
# from $FB_OPTS. Defined in the shell that sources the lib, so the lib's calls hit it.
CALLS="$W/calls"
make() {
  local a
  for a in "$@"; do
    case "$a" in
      printvars) printf 'FLUENT_BIT_CONF_OPTS=%s\n' "${FB_OPTS:-}"; return 0;;
      *-dirclean) echo "${a%-dirclean}" >> "$CALLS"; return 0;;
    esac
  done
  return 0
}

load() { # load LIBFILE
  # shellcheck source=/dev/null
  . "$1"
  for f in ga_pkg_inputs_fingerprint ga_pkg_inputs_rebuild_if_changed ga_pkg_inputs_record; do
    declare -F "$f" >/dev/null || { echo "  FAIL  PKGIN-00: $f not defined by $1"; return 1; }
  done
}
load "$LIB" || exit 1
_pass "PKGIN-00: live functions found in scripts/lib/pkg-inputs.sh"

OUT="$W/out" PATCHES="$W/patches"
mkdir -p "$OUT" "$PATCHES/libglib2" "$PATCHES/xz"
echo 'patch A' > "$PATCHES/libglib2/0101-a.patch"
echo 'patch X' > "$PATCHES/xz/0101-x.patch"
export FB_OPTS='-DFLB_MINIMAL=On -DFLB_OUT_LOKI=On'

run() { : > "$CALLS"; ga_pkg_inputs_rebuild_if_changed "$OUT" "ext" "$PATCHES" >/dev/null 2>&1; echo $? > "$W/rc"; sort "$CALLS" | tr '\n' ' ' | sed 's/ $//'; }
expect() { # expect NAME "pkgs"
  local got; got="$(run)"
  if [ "$got" = "$2" ]; then _pass "$1: rebuilt [$got]"; else _fail "$1: rebuilt [$got], want [$2]"; fi
}
record() { ga_pkg_inputs_record "$OUT" "ext" "$PATCHES"; }

expect "PKGIN-01 no record in this tree (every pre-existing tree)" "fluent-bit libglib2 xz"
record
expect "PKGIN-02 nothing changed since the last good build" ""
echo 'patch B' > "$PATCHES/libglib2/0102-b.patch"
expect "PKGIN-03 a patch was added to libglib2" "libglib2"
record
echo 'patch X, edited' > "$PATCHES/xz/0101-x.patch"
expect "PKGIN-04 a patch of xz was edited (same name)" "xz"
record
mv "$PATCHES/libglib2/0102-b.patch" "$PATCHES/libglib2/0103-b.patch"
expect "PKGIN-05 a patch of libglib2 was renamed (order matters)" "libglib2"
record
FB_OPTS='-DFLB_MINIMAL=On -DFLB_OUT_LOKI=On -DFLB_IN_TAIL=On'
expect "PKGIN-06 fluent-bit configure options changed" "fluent-bit"
record
expect "PKGIN-07 recorded again, quiet" ""
# fail closed: printvars answered nothing for fluent-bit
FB_OPTS=''
: > "$CALLS"; ga_pkg_inputs_rebuild_if_changed "$OUT" "ext" "$PATCHES" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then _pass "PKGIN-08 unreadable fluent-bit options: refuses (rc=$rc), does not guess"; else _fail "PKGIN-08 unreadable fluent-bit options: rc=0"; fi
FB_OPTS='-DFLB_MINIMAL=On -DFLB_OUT_LOKI=On -DFLB_IN_TAIL=On'

# --- mutant: fingerprint by file NAMES only -----------------------------------
sed 's/\$(sha256sum < "\$_root\/\$_pkg\/\$_f" | cut -d. . -f1)/x/' "$LIB" > "$W/mutant.sh"
if cmp -s "$LIB" "$W/mutant.sh"; then
  _fail "PKGIN-M0 the mutant did not differ from the live lib (sed pattern stale) -- the test would prove nothing"
else
  load "$W/mutant.sh" || exit 1
  rm -rf "$OUT" && mkdir -p "$OUT"
  record
  echo 'patch X, edited again' > "$PATCHES/xz/0101-x.patch"
  got="$(run)"
  if [ -z "$got" ]; then _pass "PKGIN-M1 mutant (names only) misses an edited patch -- PKGIN-04 would catch it"
  else _fail "PKGIN-M1 mutant still rebuilt [$got] -- the fixtures cannot tell it from the live lib"; fi
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
