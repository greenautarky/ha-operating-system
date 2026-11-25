#!/usr/bin/env bash
# check-patch-version-dirs.sh [--list FILE]
#
# A version directory beside *.patch files is red. Buildroot (package/pkg-utils.mk, pkg-patches-dirs)
# takes patches from <dir>/<package version>/ INSTEAD of <dir>/ as soon as that directory exists, even when
# it holds only a .hash file, and says nothing: the build stays green without the patches. That dropped the
# three DSGW-210 kernel patches from 2026-10-18 to 2026-11-25.
#
# Inspects the TRACKED files of this repository (git ls-files; the haos submodule and symlinks into it are
# upstream's and not inspected). --list FILE: one path per line instead (fixtures).
# Exit 0 clean, 1 finding, 2 nothing inspected or unreadable (fail closed).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
if [ "${1:-}" = --list ]; then files="$(cat "${2:?file}")" || exit 2; else files="$(git ls-files)" || exit 2; fi
printf '%s\n' "$files" | awk '
  # a package patch directory = the directory of a *.patch under a patches*/ tree
  /(^|\/)patches[^\/]*\/.*\.patch$/ { d = $0; sub(/\/[^\/]*$/, "", d); dirs[d]++ }
  { all[NR] = $0 }
  END {
    for (d in dirs) n++
    for (i = 1; i <= NR; i++) {
      f = all[i]
      for (d in dirs) {
        if (index(f, d "/") != 1) continue
        rest = substr(f, length(d) + 2)
        if (rest !~ /^v?[0-9][^\/]*\//) continue
        v = rest; sub(/\/.*/, "", v)
        if (!((d, v) in seen)) { seen[d, v] = 1; bad++; printf "  BAD   %s/%s/ exists: Buildroot skips the %d patch(es) in %s/ for version %s\n", d, v, dirs[d], d, v }
      }
    }
    printf "patch directories: %d inspected, %d with a version directory beside their patches\n", n, bad
    exit (n == 0 ? 2 : (bad ? 1 : 0))
  }'
