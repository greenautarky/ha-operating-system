#!/usr/bin/env bash
# selftest: scripts/check-no-workstation-paths.sh is RED on a repo that hard-codes a person's home directory and
# GREEN on one that does not. The bad strings are assembled from pieces so this file does not trip the gate.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$ROOT/scripts/check-no-workstation-paths.sh"
[ -x "$GATE" ] || { echo "FATAL: $GATE missing"; exit 2; }
W="$(mktemp -d "${TMPDIR:-/tmp}/wsp-XXXXXX")"; trap 'rm -rf "$W"' EXIT
fails=0; ran=0
ok()  { ran=$((ran+1)); echo "  ok    $1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); echo "  FAIL  $1"; }
H="/ho""me"; U="/Us""ers"
mk() { # mk <name> <file> <content>
  local r="$W/$1"; mkdir -p "$r/$(dirname "$2")"; git -C "$r" init -q 2>/dev/null; printf '%s\n' "$3" > "$r/$2"; git -C "$r" add -A; echo "$r"
}
expect() { out="$("$GATE" "$3" 2>&1)"; rc=$?; [ "$rc" = "$1" ] && ok "$2 (rc=$rc)" || { bad "$2: rc=$rc, wanted $1"; echo "$out" | sed 's/^/        /'; }; }
echo "must-flag:"
expect 1 "shell default under a person's home"      "$(mk a tests/x.sh "D=\"\${D:-$H/alice/git/repo}\"")"
expect 1 "path in a comment"                        "$(mk b scripts/y.sh "# see $H/bob.smith/notes")"
expect 1 "macOS home"                               "$(mk c docs/z.md "run $U/carol/work/x")"
expect 1 "path inside a Python string"              "$(mk d t.py "P = '$H/dave_1/x'")"
expect 1 "builder-lookalike is not the builder"     "$(mk e s.sh "X=$H/builder2/x")"
expect 2 "empty repo fails closed"                  "$(mkdir -p "$W/f"; git -C "$W/f" init -q; echo "$W/f")"
echo "must-pass:"
expect 0 "build host service account"               "$(mk g s.sh "X=$H/builder/ha-operating-system/ga_output")"
expect 0 "CI runner account"                        "$(mk h s.sh "X=$H/runner/work/x")"
expect 0 "\$HOME-relative default"                  "$(mk i s.sh 'X="${GA_REPOS_DIR:-$HOME/git}/repo"')"
expect 0 "placeholder"                              "$(mk j README.md "scp img $H/<user>/img.xz")"
expect 0 "the word home in prose"                   "$(mk k README.md 'go /home, then /homepage')"
echo "live tree:"
expect 0 "this checkout hard-codes no workstation path" "$ROOT"
[ "$ran" -ge 12 ] || { echo "FAIL: only $ran cases"; exit 1; }
echo "$ran cases ran, $fails failed"; exit $((fails>0))
