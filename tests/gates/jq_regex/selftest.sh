#!/usr/bin/env bash
# jq_regex/selftest.sh - device-side jq programs must not use regex builtins (Odoo #1720).
# The image's jq has no oniguruma; see lint.py for the scanned set and the reason.
# Fixtures: must-fail/*.sh must each yield >=1 program AND >=1 violation; must-pass/*.sh >=1
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
for f in "$HERE"/must-fail/*.sh; do
  nf=$((nf + 1)); out="$(python3 "$HERE/lint.py" --file "$f")"
  case "$out" in
    *"programs=0 "*) bad "must-fail $(basename "$f"): no jq program extracted" ;;
    *"violations=[]"*) bad "must-fail $(basename "$f"): NOT flagged" ;;
    *) ok "must-fail $(basename "$f") flagged" ;;
  esac
done
for f in "$HERE"/must-pass/*.sh; do
  np=$((np + 1)); out="$(python3 "$HERE/lint.py" --file "$f")"
  case "$out" in
    *"programs=0 "*) bad "must-pass $(basename "$f"): no jq program extracted" ;;
    *"violations=[]"*) ok "must-pass $(basename "$f") clean" ;;
    *) bad "must-pass $(basename "$f") flagged: $out" ;;
  esac
done
[ "$nf" -ge 12 ] && [ "$np" -ge 4 ] || { echo "ERROR: fixture sets incomplete ($nf/$np)" >&2; exit 2; }

echo "live:"
out="$(python3 "$HERE/lint.py")"; rc=$?
echo "  $out" | head -5
[ "$rc" -eq 0 ] && ok "live tree clean" || bad "live tree fails"

echo "red (temp copy, injection into a real overlay script):"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
for d in buildroot-external buildroot-ihost buildroot-dsgw210; do mkdir -p "$W/$d"; cp -a "$ROOT/$d/." "$W/$d/"; done
T="$W/buildroot-external/rootfs-overlay/usr/libexec/ga-host-stats"
[ -f "$T" ] || { echo "ERROR: injection target missing" >&2; exit 2; }
printf '\njq -r %s f\n' "'.a|test(\"x\")'" >> "$T"
red="$(python3 "$HERE/lint.py" --root "$W")"
if printf %s "$red" | grep -q VIOLATION; then ok "injected regex jq is flagged"; else bad "injection NOT flagged - gate cannot fail"; fi
# blind extraction must fail closed: an empty tree has zero programs
mkdir -p "$W/empty"
python3 "$HERE/lint.py" --root "$W/empty" >/dev/null 2>&1 && bad "zero programs did not fail" || ok "zero programs fails closed"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
