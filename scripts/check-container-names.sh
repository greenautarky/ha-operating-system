#!/bin/sh
# check-container-names.sh <dir>... - fail on device-side code that names an add-on
# container with the pre-2026.10 prefix only. Supervisor 2026.10+ (BOSv1.6) names
# them app_<hash>_<slug>; addon_<hash>_<slug> is BOSv1.5.x. A grep anchored on
# `^addon_` or a `docker exec addon_...` is blind on BOSv1.6 (measured 2026-11-10).
# Use ga_ctr_of / ga_ctr_exact (tests/ga_tests/lib/test_helpers.sh) or `(app|addon)_`.
# A line that also names app_ is accepted. Prose in comments (#) is ignored.
# rc 0 clean, 1 hits, 2 inspected nothing (fails closed).
set -u
PAT='(\^"?addon_|docker +(exec|inspect|cp|logs|restart|stop|start|rm|kill|top)( +-[-a-z]+( +[^ -][^ ]*)?)* +"?addon_|docker +cp +[^ ]+ +"?addon_|["'"'"' ]addon_[0-9a-f]{8}_)'
n=0; hits=0
for root in "$@"; do
  if [ -f "$root" ]; then list="$root"; elif [ -d "$root" ]; then list="$(find "$root" -type f -not -path '*/fixtures/*' 2>/dev/null)"; else continue; fi
  for f in $list; do
    case "$f" in *.sh|*.md|*.py|*.service|*.conf|*/ga-*) ;; *) continue ;; esac
    n=$((n + 1))
    out="$(grep -nE "$PAT" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v 'app_')" || true
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | sed "s|^|$f:|"
      hits=$((hits + 1))
    fi
  done
done
[ "$n" -gt 0 ] || { echo "check-container-names: ERROR: inspected 0 files" >&2; exit 2; }
if [ "$hits" -gt 0 ]; then echo "check-container-names: $hits file(s) name addon_* containers only (BOSv1.6 uses app_*)" >&2; exit 1; fi
echo "check-container-names: $n file(s) clean"
