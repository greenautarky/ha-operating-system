#!/usr/bin/env bash
# Self-test of scripts/check-haos-unit-names.sh (Odoo #1738). Runs the LIVE gate:
#   must-fail/*  -> rc 1 and a FINDING line (each fixture is a mini device tree)
#   must-pass/*  -> rc 0 (incl. partition labels, haos-* names, out-of-scope files)
#   allowlist    -> the live alias symlink path passes, the same name elsewhere fails
#   fail closed  -> missing scan roots / zero files = rc 2
#   live tree    -> every allowlist entry still exists AND still earns its keep
#                   (a stale exemption is a hole), then the gate is green on it
# The gate's allowlist and pattern are read from the live script, not copied.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; repo="$(cd "$here/../../.." && pwd)"
gate="$repo/scripts/check-haos-unit-names.sh"
[ -x "$gate" ] || { echo "FAIL: gate missing or not executable: $gate"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
bad=0 nf=0 np=0
indent() { sed 's/^/        /'; }
scaffold() { # $1 dir: give it the three scan roots so only the fixture content differs
  mkdir -p "$1/buildroot-external" "$1/buildroot-ihost" "$1/tests/ga_tests"
  for r in buildroot-external buildroot-ihost tests/ga_tests; do : > "$1/$r/.keep"; done
}
for d in "$here"/must-fail/*/ "$here"/must-pass/*/; do
  [ -d "$d" ] || continue
  kind="$(basename "$(dirname "$d")")"; name="$(basename "$d")"
  w="$T/$kind-$name"; mkdir -p "$w"; cp -a "$d/." "$w/"; scaffold "$w"
  out="$("$gate" "$w" 2>&1)"; rc=$?
  if [ "$kind" = must-fail ]; then
    nf=$((nf+1))
    if [ "$rc" -eq 1 ] && grep -q '^FINDING:' <<<"$out"; then echo "  ok    must-fail/$name"
    else echo "  FAIL  must-fail/$name (rc=$rc)"; indent <<<"$out"; bad=1; fi
  else
    np=$((np+1))
    if [ "$rc" -eq 0 ]; then echo "  ok    must-pass/$name"
    else echo "  FAIL  must-pass/$name (rc=$rc)"; indent <<<"$out"; bad=1; fi
  fi
done

# allowlist, read from the LIVE gate
mapfile -t ALLOW < <(HAOS_UNIT_NAMES_PRINT_ALLOW=1 "$gate" | grep -v '^PATTERN=')
[ "${#ALLOW[@]}" -ge 1 ] || { echo "FAIL: could not extract the allowlist from the gate"; exit 1; }
alias_path=buildroot-external/rootfs-overlay/etc/systemd/system/hassos-supervisor.service
w="$T/allow-alias"; mkdir -p "$w/${alias_path%/*}"; scaffold "$w"
ln -s /usr/lib/systemd/system/haos-supervisor.service "$w/$alias_path"
"$gate" "$w" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then echo "  ok    allowlist: the alias symlink at its pinned path passes"; else echo "  FAIL  allowlist: alias path rc=$rc"; bad=1; fi
w="$T/allow-elsewhere"; mkdir -p "$w/buildroot-external/x"; scaffold "$w"
ln -s /usr/lib/systemd/system/haos-supervisor.service "$w/buildroot-external/x/hassos-supervisor.service"
"$gate" "$w" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then echo "  ok    allowlist: the same symlink at another path fails"; else echo "  FAIL  allowlist: other path rc=$rc (want 1)"; bad=1; fi

# fail closed
w="$T/no-roots"; mkdir -p "$w"; "$gate" "$w" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then echo "  ok    missing scan roots -> rc=2"; else echo "  FAIL  missing scan roots -> rc=$rc"; bad=1; fi
w="$T/zero-files"; mkdir -p "$w/buildroot-external" "$w/buildroot-ihost" "$w/tests/ga_tests"; "$gate" "$w" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then echo "  ok    zero files inspected -> rc=2"; else echo "  FAIL  zero files -> rc=$rc"; bad=1; fi

# live tree: allowlist entries exist and still match (no stale exemption), then green
for p in "${ALLOW[@]}"; do
  f="$repo/$p"
  if [ -L "$f" ] || { [ -f "$f" ] && grep -qE "$(HAOS_UNIT_NAMES_PRINT_ALLOW=1 "$gate" | sed -n 's/^PATTERN=//p')" "$f"; }; then echo "  ok    allowlist entry live: $p"
  else echo "  FAIL  stale allowlist entry (missing or no longer matches): $p"; bad=1; fi
done
out="$("$gate" "$repo" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then echo "  ok    live tree: $out"; else echo "  FAIL  live tree rc=$rc"; indent <<<"$out"; bad=1; fi

if [ "$nf" -lt 7 ] || [ "$np" -lt 3 ]; then echo "FAIL: only $nf must-fail / $np must-pass fixtures inspected"; exit 1; fi
echo "$((nf+np)) fixtures inspected ($nf must-fail, $np must-pass) + allowlist, fail-closed and live-tree checks"
exit "$bad"
