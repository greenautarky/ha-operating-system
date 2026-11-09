#!/bin/sh
# selftest.sh — the data-root gate (scripts/check-data-root.py) goes red on every
# hard-coded Supervisor data root and green on resolver users, and refuses to
# pass over nothing. Runs the LIVE script; then the live repo, which must be
# clean with a non-trivial number of inspected files and the resolver present.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
CHECK="$REPO/scripts/check-data-root.py"
[ -f "$CHECK" ] || { echo "FATAL: $CHECK missing"; exit 1; }
fails=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fails=$((fails + 1)); }
for d in "$HERE"/must-fail/*/; do
  [ -d "$d" ] || continue
  out="$(python3 "$CHECK" "$d" 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && ok "must-fail $(basename "$d")" || bad "must-fail $(basename "$d") rc=$rc: $out"
done
for d in "$HERE"/must-pass/*/; do
  [ -d "$d" ] || continue
  out="$(python3 "$CHECK" "$d" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "must-pass $(basename "$d")" || bad "must-pass $(basename "$d") rc=$rc: $out"
done
e="$(mktemp -d)"; python3 "$CHECK" "$e" >/dev/null 2>&1; rc=$?; rmdir "$e"
[ "$rc" -eq 2 ] && ok "empty root fails closed (rc 2)" || bad "empty root rc=$rc, want 2"
[ -f "$REPO/buildroot-external/rootfs-overlay/usr/libexec/ga-data-root.sh" ] && ok "resolver present" || bad "resolver missing"
# Scope: everything that ships or runs in the build (OS overlays, scripts/, the workflows).
# tests/ is EXEMPT on purpose: those files build fake Supervisor trees (and the fixtures
# above spell the hard-coded root by design) to drive the resolver and its consumers.
out="$(python3 "$CHECK" "$REPO/buildroot-external" "$REPO/buildroot-ihost" "$REPO/buildroot-dsgw210" "$REPO/scripts" "$REPO/.github" 2>&1)"; rc=$?
n="$(printf '%s\n' "$out" | sed -n 's/^check-data-root: \([0-9]*\) files inspected.*/\1/p')"
[ "$rc" -eq 0 ] && ok "live tree clean" || bad "live tree rc=$rc: $out"
[ "${n:-0}" -ge 300 ] && ok "live tree: $n files inspected" || bad "live tree inspected only ${n:-0} files"
echo "data_root gate selftest: $fails failure(s)"
[ "$fails" -eq 0 ]
