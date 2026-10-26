#!/bin/bash
# journald-effective.sh — the journald setting that actually applies.
#
#   source scripts/lib/journald-effective.sh
#   jd_effective <Key> <root>...      prints the effective value (empty = unset)
#
# <root> is a rootfs or rootfs overlay; with several, they are layered in the
# given order like Buildroot's BR2_ROOTFS_OVERLAY (a later root's file of the
# same path replaces the earlier one). journald reads etc/systemd/journald.conf,
# then every journald.conf.d/*.conf from usr/lib/systemd and etc/systemd, sorted
# by file name (a file in etc/ replaces a same-named one in usr/lib/); the last
# assignment of a key wins. Reading only the main file misses a drop-in that
# overrides it — which is how a "Storage=volatile" was undone by a board drop-in.
jd_effective() {
  local key="$1"; shift
  local r f n val="" main="" ; declare -A drop=()
  for r in "$@"; do
    [ -f "$r/etc/systemd/journald.conf" ] && main="$r/etc/systemd/journald.conf"
    for d in usr/lib/systemd/journald.conf.d etc/systemd/journald.conf.d; do
      for f in "$r/$d"/*.conf; do [ -f "$f" ] && drop["$(basename "$f")"]="$f"; done
    done
  done
  for f in $main $(for n in "${!drop[@]}"; do echo "$n"; done | LC_ALL=C sort | while read -r n; do echo "${drop[$n]}"; done); do
    n="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$f" | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
    [ -n "$n" ] && val="$n"
  done
  printf '%s' "$val"
}
