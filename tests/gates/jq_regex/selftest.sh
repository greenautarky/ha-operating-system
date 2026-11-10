#!/usr/bin/env bash
# jq_regex/selftest.sh - device-side jq programs must not use regex builtins (Odoo #1720).
# The image's jq has no oniguruma; see lint.py for the scanned set and the reason.
# Fixtures: must-fail/*.txt must each yield >=1 program AND >=1 violation; must-pass/*.txt >=1
# program and none. Live: lint.py over the real tree must be green. RED: a temp copy of the
# scanned dirs with a regex jq injected into a real overlay script must make the gate fail.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ok    $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }
command -v python3 >/dev/null || { echo "ERROR: python3 missing" >&2; exit 2; }

echo "fixtures:"
nf=0 np=0
for f in "$HERE"/must-fail/*.txt; do
  nf=$((nf + 1)); out="$(python3 "$HERE/lint.py" --file "$f")"; b="$(basename "$f")"
  case "$out" in
    *"violations=[]"*) bad "must-fail $b: NOT flagged" ;;
    *"programs=0 "*) case "$b" in py_*) ok "must-fail $b flagged" ;; *) bad "must-fail $b: no jq program extracted" ;; esac ;;
    *) ok "must-fail $b flagged" ;;
  esac
done
for f in "$HERE"/must-pass/*.txt; do
  np=$((np + 1)); out="$(python3 "$HERE/lint.py" --file "$f")"
  case "$out" in
    *"programs=0 "*) bad "must-pass $(basename "$f"): no jq program extracted" ;;
    *"violations=[]"*) ok "must-pass $(basename "$f") clean" ;;
    *) bad "must-pass $(basename "$f") flagged: $out" ;;
  esac
done
[ "$nf" -ge 20 ] && [ "$np" -ge 9 ] || { echo "ERROR: fixture sets incomplete ($nf/$np)" >&2; exit 2; }

echo "live:"
out="$(python3 "$HERE/lint.py")"; rc=$?
printf '%s\n' "$out" | sed 's/^/  /'
[ "$rc" -eq 0 ] && ok "live tree clean" || bad "live tree fails"

echo "red (temp copy of the tree; injections into real files):"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
for d in buildroot-external buildroot-ihost buildroot-dsgw210; do mkdir -p "$W/$d"; cp -a "$ROOT/$d/." "$W/$d/"; done
OV=buildroot-external/rootfs-overlay/usr
red() { # red <label> <file-rel> <text>: inject into the copy, expect a VIOLATION, restore
  local f="$W/$2" keep; keep="$(mktemp)"; mkdir -p "$(dirname "$f")"
  [ -f "$f" ] && cp "$f" "$keep" || : > "$keep.new"
  printf '\n%s\n' "$3" >> "$f"
  local r; r="$(python3 "$HERE/lint.py" --root "$W")"
  if printf %s "$r" | grep -q VIOLATION; then ok "$1 flagged"; else bad "$1 NOT flagged - gate cannot fail"; fi
  if [ -e "$keep.new" ]; then rm -f "$f" "$keep.new"; else cp "$keep" "$f"; fi; rm -f "$keep"
}
[ -f "$W/$OV/libexec/ga-host-stats" ] || { echo "ERROR: injection target missing" >&2; exit 2; }
red "plain regex jq"                 $OV/libexec/ga-host-stats "jq -r '.a|test(\"x\")' f"
red "shape 1: jq in \"\$( )\""         $OV/libexec/ga-host-stats 'x="$(printf %s "$y" | jq -r '"'"'.a|test("x")'"'"')"'
red "shape 2: \"\$JQ\" command word"   $OV/sbin/ga-telemetry-profile-apply '"$JQ" -r '"'"'.a|sub("a";"b")'"'"' f'
red "new unpinned jq program"        $OV/libexec/ga-host-stats "jq -r '.a' f"
red "jq file under board/ (completeness)" buildroot-ihost/board/sonoff/ihost/zz-injected.sh "jq -r '.a' f"
# blind extraction must fail closed: an empty tree has no files / no pinned programs
mkdir -p "$W/empty"
python3 "$HERE/lint.py" --root "$W/empty" >/dev/null 2>&1 && bad "empty tree did not fail" || ok "empty tree fails closed"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
