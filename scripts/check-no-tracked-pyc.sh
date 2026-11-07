#!/usr/bin/env bash
# check-no-tracked-pyc.sh [REPO_DIR] -- fail if any compiled Python file (*.pyc, *.pyo) or anything under
# __pycache__/ is tracked by git in REPO_DIR (default: the repo this script lives in).
# Why: a tracked .pyc is rewritten whenever a gate imports the script next to it, so every gate run leaves
# a modified file behind (Odoo #1632). Fails closed when git lists no file at all (a gate that inspected
# nothing is not a pass). Selftest: tests/gates/tracked_pyc/selftest.sh
set -u
dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
files="$(git -C "$dir" ls-files -z 2>/dev/null | tr '\0' '\n')" || files=""
n="$(printf '%s\n' "$files" | grep -c .)"
if [ "$n" -eq 0 ]; then echo "FAIL: git lists no tracked file in '$dir' -- nothing was inspected"; exit 2; fi
bad="$(printf '%s\n' "$files" | grep -E '(^|/)__pycache__/|\.py[co]$' || true)"
if [ -n "$bad" ]; then
  echo "FAIL: compiled Python files are tracked (git rm --cached them; .gitignore keeps them out):"
  printf '%s\n' "$bad" | sed 's/^/  /'
  exit 1
fi
echo "PASS: no compiled Python file is tracked ($n files inspected)"
