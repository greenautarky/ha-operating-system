#!/usr/bin/env bash
# selftest: scripts/check-no-tracked-pyc.sh is RED on a repo that tracks a .pyc / __pycache__ file and GREEN on a
# clean one. The fixtures are real throwaway git repos; the gate under test is the live script.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$ROOT/scripts/check-no-tracked-pyc.sh"
[ -x "$GATE" ] || { echo "FATAL: $GATE missing"; exit 2; }
W="$(mktemp -d "${TMPDIR:-/tmp}/pyc-XXXXXX")"; trap 'rm -rf "$W"' EXIT
fails=0; ran=0
ok()  { ran=$((ran+1)); echo "  ok    $1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); echo "  FAIL  $1"; }
mk() { # mk <name> <file>... : a repo tracking exactly these files
  local r="$W/$1"; shift; mkdir -p "$r"; git -C "$r" init -q
  for f in "$@"; do mkdir -p "$r/$(dirname "$f")"; echo x > "$r/$f"; done
  git -C "$r" add -A; echo "$r"
}
expect() { # expect <rc> <label> <repo>
  out="$("$GATE" "$3" 2>&1)"; rc=$?
  [ "$rc" = "$1" ] && ok "$2 (rc=$rc)" || { bad "$2: rc=$rc, wanted $1"; echo "$out" | sed 's/^/        /'; }
}
echo "must-flag:"
expect 1 "tracked scripts/__pycache__/x.cpython-313.pyc" "$(mk a a.py scripts/__pycache__/x.cpython-313.pyc)"
expect 1 "tracked top-level .pyc" "$(mk b a.py stray.pyc)"
expect 1 "tracked .pyo" "$(mk c a.py m.pyo)"
expect 1 "tracked non-.pyc file inside __pycache__/" "$(mk d a.py pkg/__pycache__/notes.txt)"
expect 2 "empty repo: fails closed (nothing inspected)" "$(mk e)"
echo "must-pass:"
expect 0 "scripts and a file named pyc-notes.md" "$(mk f scripts/a.py scripts/b.sh pyc-notes.md docs/pycache.md)"
r="$(mk g a.py)"; mkdir -p "$r/__pycache__"; echo x > "$r/__pycache__/a.pyc"   # untracked pyc on disk is fine
expect 0 "an UNTRACKED .pyc on disk" "$r"
echo "live tree:"
expect 0 "this checkout tracks no compiled Python file" "$ROOT"
[ "$ran" -ge 8 ] || { echo "FAIL: only $ran cases"; exit 1; }
echo "$ran cases ran, $fails failed"; exit $((fails>0))
