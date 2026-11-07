#!/usr/bin/env bash
# check-no-workstation-paths.sh [REPO_DIR] -- fail if a tracked text file names a person's home directory
# (/home/<name>/..., /Users/<name>/...). Such a path judges a different thing on every machine: SKIP on CI,
# something else on a laptop (Odoo #1632), and it leaks who works where into a public repo.
# Allowed: /home/builder and /home/runner (the shared build host's and the CI runner's service accounts -- roles,
# not people). Use an env var with a $HOME-relative default instead (e.g. ${GA_REPOS_DIR:-$HOME/git}).
# Fails closed when no text file was inspected. Selftest: tests/gates/workstation_paths/selftest.sh
set -u
dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ALLOWED='builder|runner'
n=0; hits=""
while IFS= read -r -d '' f; do
  [ -f "$dir/$f" ] && [ ! -L "$dir/$f" ] || continue          # gitlinks (submodules) and symlinks are not files here
  grep -Iq . "$dir/$f" 2>/dev/null || continue                 # binary or empty
  n=$((n+1))
  h="$(grep -InoE '(/home|/Users)/[A-Za-z0-9_.-]+' "$dir/$f" 2>/dev/null | grep -vE "/home/(${ALLOWED})\$" || true)"
  [ -n "$h" ] && hits="${hits}$(printf '%s\n' "$h" | sed "s#^#  $f:#")"$'\n'
done < <(git -C "$dir" ls-files -z)
if [ "$n" -eq 0 ]; then echo "FAIL: no tracked text file inspected in '$dir'"; exit 2; fi
if [ -n "$hits" ]; then
  echo "FAIL: workstation paths are hard-coded (use an env var with a \$HOME-relative default):"
  printf '%s' "$hits"; exit 1
fi
echo "PASS: no workstation path in $n tracked text files"
