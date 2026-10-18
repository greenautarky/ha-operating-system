#!/usr/bin/env bash
# release_suffix selftest — scripts/release.sh bumps the OS version on the HAOS
# 18.x layout, where `meta` is an upstream file and the GA suffix is one line of
# the GA patch buildroot-external/patches-haos/0101-ga-meta-product-name.patch.
#
# It drives the LIVE scripts/release.sh end to end in a sandbox of three git
# repos (supervisor, haos-version, ha-operating-system; nothing is pushed) and
# reads the result back through the applier, the way the build reads meta.
#
#   must-pass   18.3.1.7 -> patch 0101 now carries "1.7"; the patched meta reads
#               VERSION_MAJOR.MINOR.SUFFIX = 18.3.1.7; stable.json and the
#               commit carry it; the patch is the committed file
#   must-fail   a base other than the pinned haos/ (19.0.1.7), a version
#               without a suffix (18.3), a patch with two / no VERSION_SUFFIX
#               lines, a malformed suffix: exit != 0 and the patch is untouched
#
# Needs the haos/ submodule checked out (a missing one FAILS, never skips).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../../../scripts/lib/tree-paths.sh
. "$REPO/scripts/lib/tree-paths.sh"
RC=0
ok()   { echo "  ok    $1"; }
bad()  { echo "  FAIL  $1"; RC=1; }

[ -f "$REPO/$GA_HAOS_DIR/buildroot-external/meta" ] || { echo "  FAIL  $GA_HAOS_DIR/ submodule not checked out - the version cannot be read"; exit 1; }
# Pinned constants, read from the UPSTREAM file (not from what release.sh prints).
MAJ="$(sed -n -E 's/^VERSION_MAJOR="([^"]*)".*/\1/p' "$REPO/$GA_HAOS_DIR/buildroot-external/meta")"
MIN="$(sed -n -E 's/^VERSION_MINOR="([^"]*)".*/\1/p' "$REPO/$GA_HAOS_DIR/buildroot-external/meta")"
[ -n "$MAJ" ] && [ -n "$MIN" ] || { echo "  FAIL  cannot read VERSION_MAJOR/MINOR from upstream meta"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkgit() { git -C "$1" init -q -b "$2" && git -C "$1" -c user.email=t@t -c user.name=t add -A && git -C "$1" -c user.email=t@t -c user.name=t commit -q -m init; }

sandbox() { # $1 = dir
  local d="$1"; rm -rf "$d"; mkdir -p "$d/os/scripts" "$d/os/buildroot-external" "$d/os/patches" "$d/sup/supervisor" "$d/hv"
  cp -r "$REPO/scripts/lib" "$d/os/scripts/lib"
  cp "$REPO/scripts/release.sh" "$REPO/scripts/apply-haos-patches.sh" "$d/os/scripts/"
  cp -r "$REPO/buildroot-external/patches-haos" "$d/os/buildroot-external/patches-haos"
  cp -r "$REPO/$GA_HAOS_PATCH_DIR" "$d/os/$GA_HAOS_PATCH_DIR"
  ln -s "$REPO/$GA_HAOS_DIR" "$d/os/$GA_HAOS_DIR"
  printf 'gaos_release: "BOSv1.6.0-dev1"\n' > "$d/os/version.yaml"
  printf 'SUPERVISOR_VERSION = "2025.1.0"\n' > "$d/sup/supervisor/const.py"
  printf '{"hassos":{"ihost":"%s.%s.1.6"},"supervisor":"2025.1.0","ga_release":"BOSv1.6.0-dev1"}\n' "$MAJ" "$MIN" > "$d/hv/stable.json"
  # ignore the haos symlink like the real repo's submodule would be
  printf 'haos\n' > "$d/os/.gitignore"
  mkgit "$d/os" master; mkgit "$d/sup" ga/custom-version-url; mkgit "$d/hv" main
}
run_release() { # $1=dir, rest = args
  local d="$1"; shift
  SUPERVISOR_REPO="$d/sup" HAOS_VERSION_REPO="$d/hv" bash "$d/os/scripts/release.sh" --no-push "$@" >"$d/out.log" 2>&1
}
P0101="buildroot-external/patches-haos/0101-ga-meta-product-name.patch"

# --- must-pass ---------------------------------------------------------------
sandbox "$T/pass"
if run_release "$T/pass" "$MAJ.$MIN.1.7" 2025.2.0; then
  got="$(sed -n -E 's/^\+VERSION_SUFFIX="([^"]*)".*/\1/p' "$T/pass/os/$P0101")"
  meta="$("$T/pass/os/scripts/apply-haos-patches.sh" --cat buildroot-external/meta | sed -n -E 's/^VERSION_(MAJOR|MINOR|SUFFIX)="([^"]*)".*/\2/p' | paste -sd.)"
  [ "$got" = "1.7" ] && ok "must-pass/bump: the +VERSION_SUFFIX line of patch 0101 now says 1.7" || bad "must-pass/bump: patch line says '$got'"
  [ "$meta" = "$MAJ.$MIN.1.7" ] && ok "must-pass/bump: the patched meta reads $meta (what the build sees)" || bad "must-pass/bump: patched meta reads '$meta', want $MAJ.$MIN.1.7"
  grep -q "\"ihost\": \"$MAJ.$MIN.1.7\"" "$T/pass/hv/stable.json" && ok "must-pass/bump: stable.json hassos.ihost = $MAJ.$MIN.1.7" || bad "must-pass/bump: stable.json not updated"
  git -C "$T/pass/os" show --stat --format=%s HEAD | grep -q "patches-haos/0101" && ok "must-pass/bump: the committed file is the meta patch" || bad "must-pass/bump: commit does not contain the patch"
else
  bad "must-pass/bump: release.sh exited non-zero: $(tail -3 "$T/pass/out.log" | tr '\n' ' ')"
fi

# --- must-fail ---------------------------------------------------------------
must_fail() { # name expected-message dir args...  (patch must stay byte-identical;
               # the refusal must be THIS check, not some other failure)
  local n="$1" msg="$2" d="$3"; shift 3
  local before; before="$(cat "$d/os/$P0101")"
  if run_release "$d" "$@"; then bad "must-fail/$n: release.sh succeeded"; return; fi
  grep -qF "$msg" "$d/out.log" || { bad "must-fail/$n: failed, but not with '$msg': $(tail -2 "$d/out.log" | tr '\n' ' ')"; return; }
  [ "$(cat "$d/os/$P0101")" = "$before" ] && ok "must-fail/$n: refused, patch untouched" || bad "must-fail/$n: refused but the patch changed"
}
sandbox "$T/f1"; must_fail other-base "this tree builds" "$T/f1" "19.0.1.7" 2025.2.0
sandbox "$T/f2"; must_fail no-suffix "has no GA suffix" "$T/f2" "$MAJ.$MIN" 2025.2.0
# library level (a patch the applier itself already rejects never reaches the
# edit in release.sh): refuse and leave the file alone
# shellcheck source=../../../scripts/lib/ga-os-meta.sh
. "$REPO/scripts/lib/ga-os-meta.sh"
lib_refuses() { # name patch-transform suffix expected-message
  local n="$1" tr="$2" suf="$3" msg="$4" f="$T/lib-$1.patch"
  cp "$REPO/$P0101" "$f"; [ -z "$tr" ] || sed -i "$tr" "$f"
  local before; before="$(cat "$f")"
  local err; err="$(ga_meta_set_suffix "$f" "$suf" 2>&1)" && { bad "must-fail/$n: accepted"; return; }
  [ "$(cat "$f")" = "$before" ] || { bad "must-fail/$n: refused but the file changed"; return; }
  grep -qF "$msg" <<<"$err" && ok "must-fail/$n: refused ($msg), file untouched" || bad "must-fail/$n: refused with another message: $err"
}
lib_refuses malformed-suffix ''  "1.x" "not a dotted number"
lib_refuses suffix-line-missing 's/^+VERSION_SUFFIX=.*//' "1.7" "expected exactly 1"
lib_refuses suffix-line-twice   's/^+VERSION_SUFFIX=.*/&\n&/' "1.7" "expected exactly 1"

[ "$RC" = 0 ] && echo "release_suffix: all cases behave" || echo "release_suffix: FAILED"
exit "$RC"
