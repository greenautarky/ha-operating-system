#!/usr/bin/env bash
# scripts/check-rootfs-commands.py (the LIVE script): must-flag / must-pass on small trees, the LIVE
# scripts of both boards against the recorded target of a real bake, and the LIVE 11d block of ga_build.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
GATE="$ROOT/scripts/check-rootfs-commands.py"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
ran=0; fails=0
check() { ran=$((ran+1)); if [ "$2" = 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; fails=$((fails+1)); [ -z "${3:-}" ] || echo "$3" | tail -4; fi; }
mk() { # mk <script body> [allow line]: scratch repo + target with 301 commands
  rm -rf "$W/r" "$W/t"; mkdir -p "$W/r/buildroot-external/rootfs-overlay/usr/sbin" "$W/r/buildroot-external/package" "$W/r/buildroot-ihost" "$W/t/usr/bin"
  local i; for i in $(seq 301); do : > "$W/t/usr/bin/c$i"; done
  for i in awk sed cat grep ip; do : > "$W/t/usr/bin/$i"; done
  printf '#!/bin/sh\n%s\n' "$1" > "$W/r/buildroot-external/rootfs-overlay/usr/sbin/s"
  printf '%b' "${2:-}" > "$W/r/buildroot-external/rootfs-commands.allow"
}
# min-scripts 1 also lowers the "parsed almost no calls" floor
gate() { out="$(python3 "$GATE" --board ihost --repo "$W/r" --target "$W/t" --min-scripts 1 "$@" 2>&1)"; rc=$?; }
flag() { mk "$2"; gate; { [ "$rc" = 1 ] && grep -qE "MISSING +$3:" <<<"$out"; }; check "MUST-FLAG $1" $? "$out"; }
pass() { mk "$2" "${3:-}"; gate; [ "$rc" = 0 ]; check "MUST-PASS $1" $? "$out"; }

# shellcheck disable=SC2016 # the snippets are data
{
flag "plain call"                        'logger -t x y'                                  logger
flag "the real shape: hidden by || and 2>/dev/null" '_l() { logger -t x "$1" 2>/dev/null || echo "$1"; }; _l a' logger
flag "in a pipe"                         'cat x | zgrep y'                                zgrep
flag "in a command substitution"         'a=$(getent hosts x | awk "{print}")'            getent
flag "in backticks"                      'a=`getent x`; cat x'                            getent
flag "in a quoted substitution"          'echo "v=$(sha3 x)"; cat x'                      sha3
flag "in a case arm"                     'case "$1" in a|b) logger x ;; *) cat x ;; esac' logger
flag "after if / then / !"               'if ! nope x; then cat y; fi'                    nope
flag "in a subshell and a loop"          'for i in a b; do (cat "$i"; nope "$i"); done'   nope
flag "behind timeout N"                  'timeout 5 nope x'                               nope
flag "after an assignment prefix"        'LC_ALL=C nope x; cat y'                         nope
flag "in an unquoted here-document"      'cat <<EOF
$(nope)
EOF'                                                                                      nope
flag "in a trap"                         'trap "nope x" EXIT; cat y'                      nope
flag "absolute path"                     '/usr/sbin/nope x; cat y'                        /usr/sbin/nope
pass "existing commands, builtins, functions" 'f() { cat x; }; f; printf a; [ -f x ] && export A=b; ip a | sed s/a/b/'
pass "words that are not commands"       'echo logger; cat logger # logger x
a=logger; case logger in logger) cat x ;; esac'
pass "a quoted here-document"            'cat <<'"'EOF'"'
$(nope)
EOF'
pass "strings for another container"     'cat x; echo "nope; nope2 | nope3"'
pass "probed with command -v: optional"  'if command -v nope >/dev/null; then nope x; fi; cat y'
pass "probed with [ -x ]"                '[ -x /usr/bin/nope ] && /usr/bin/nope x; cat y'
pass "an allowed call with a reason"     'nope x; cat y' 'nope\tbuildroot-external/*\tnever runs here\n'
}
mk 'cat x' 'nope\tbuildroot-external/*\tnever runs here\n'; gate; { [ "$rc" = 1 ] && grep -q STALE <<<"$out"; }; check "MUST-FLAG a stale allowlist entry" $? "$out"
mk 'cat x' 'nope\tbuildroot-external/*\t\n'; gate; [ "$rc" = 2 ]; check "MUST-FAIL-CLOSED an allowlist entry without a reason" $? "$out"
mk 'cat x'; rm -rf "$W/t"; gate; [ "$rc" = 2 ]; check "MUST-FAIL-CLOSED no target" $? "$out"
mk 'cat x'; rm "$W/t/usr/bin/"c1*; gate; [ "$rc" = 2 ]; check "MUST-FAIL-CLOSED a target with almost no commands" $? "$out"
mk 'cat x'; out="$(python3 "$GATE" --board ihost --repo "$W/r" --target "$W/t" 2>&1)"; [ $? = 2 ]; check "MUST-FAIL-CLOSED almost no scripts" $? "$out"

echo "== the LIVE scripts against the recorded targets"
for b in ihost dsgw210; do
  # only the recorded target is needed: unpacked as make-fixture.sh does, without the rest of the bake
  FX="$ROOT/tests/gates/build_tests_board_matrix/fixtures/$b"; mkdir -p "$W/fx-$b"
  tar -xJf "$FX/ga_output.tar.xz" -C "$W/fx-$b" || { echo "FATAL: cannot unpack the $b recording"; exit 2; }
  [ ! -f "$FX/reconstruct.sh" ] || bash "$FX/reconstruct.sh" "$W/fx-$b/ga_output" || { echo "FATAL: reconstruct.sh failed for $b"; exit 2; }
  T="$W/fx-$b/ga_output/target"
  # the recordings predate CONFIG_LOGGER; the command counts only while the fragment really sets it
  plus=(); grep -qx 'CONFIG_LOGGER=y' "$ROOT/buildroot-external/busybox-ga.fragment" && [ ! -e "$T/usr/bin/logger" ] && plus=(--plus logger)
  out="$(python3 "$GATE" --board "$b" --target "$T" "${plus[@]}" 2>&1)"; rc=$?
  echo "        $(tail -1 <<<"$out")"
  # the status goes through a variable: a $(...) in the message would replace $? before it is read
  { [ "$rc" = 0 ] && grep -qE "$b: [0-9]{2,} scripts, [0-9]{3,} calls, .* 0 missing" <<<"$out"; }; st=$?
  check "$b: every command exists" "$st" "$out"
  if [ "${#plus[@]}" -gt 0 ]; then
    out="$(python3 "$GATE" --board "$b" --target "$T" 2>&1)"; rc=$?
    { [ "$rc" = 1 ] && grep -q 'MISSING   logger' <<<"$out" && [ "$(grep -c MISSING <<<"$out")" = 1 ]; }; check "$b: RED without logger, and only for logger" $? "$out"
  fi
done

echo "== the LIVE 11d block of ga_build.sh"
sed -n '/^# 11d) /,/^# Post-build integrity checks/p' "$ROOT/scripts/ga_build.sh" > "$W/11d.sh"
[ "$(grep -c check-rootfs-commands.py "$W/11d.sh")" -ge 1 ]; check "the block is there and calls the gate" $?
for want in 0 1 2; do
  mkdir -p "$W/s" "$W/o/images/reports"; printf 'import sys\nsys.exit(%s)\n' "$want" > "$W/s/check-rootfs-commands.py"
  ( set -euo pipefail; SCRIPT_DIR="$W/s" OUT="$W/o" BOARD=ihost; . "$W/11d.sh" ) >/dev/null 2>&1; rc=$?
  if [ "$want" = 0 ]; then [ "$rc" = 0 ]; else [ "$rc" != 0 ]; fi; st=$?
  check "gate exit $want -> build $([ "$want" = 0 ] && echo goes on || echo stops)" "$st"
done
echo "rootfs_commands selftest: $ran checks, $fails failed"
[ "$ran" -ge 34 ] || { echo "FATAL: only $ran checks ran"; exit 2; }
[ "$fails" = 0 ]
