#!/usr/bin/env bash
# selftest: the build tests that read the retired frontend/core/supervisor forks (SRC-14..16, BLD-ADMIN, BLD-SUP-DNS,
# INT-05) look for them ONLY under $GA_SIBLING_REPOS (Odoo #1632). Drives the LIVE runner on the iHost fixture bake
# (tests/gates/build_tests_board_matrix/run-board.sh) with synthetic sibling checkouts:
#   unset / empty / missing dir -> a loud NOTE and SKIP, never a guess (no workstation path is consulted)
#   siblings present and RIGHT  -> the checks run and PASS (must-pass)
#   siblings present and WRONG  -> the checks FAIL (must-flag), so the env var really reaches the checks
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
BM="$ROOT/tests/gates/build_tests_board_matrix"
[ -d "$ROOT/haos/buildroot-external" ] || { echo "FATAL: haos submodule not checked out (git submodule update --init --depth 1 haos)"; exit 2; }
for t in jq python3 tar xz strings; do command -v "$t" >/dev/null || { echo "FATAL: $t missing"; exit 2; }; done
W="$(mktemp -d "${TMPDIR:-/tmp}/sib-XXXXXX")"; trap 'rm -rf "$W"' EXIT
fails=0; ran=0
ok()  { ran=$((ran+1)); echo "  ok    $1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); echo "  FAIL  $1"; }
has() { grep -qE "$2" "$1"; }
run() { # run <label> [ENV=VAL...] -> $W/<label>.out
  local l="$1"; shift
  env -u GA_SIBLING_REPOS "$@" "$BM/run-board.sh" ihost "$W/w-$l" > "$W/$l.out" 2>&1
  [ "$(grep -cE '^ +(PASS|FAIL|SKIP) ' "$W/$l.out")" -ge 300 ] || { bad "$l: the runner did not run to its verdicts"; tail -n 3 "$W/$l.out"; return 1; }
}
# synthetic siblings. The host names are the ones the live runner reads from ga-services.conf.
mk_siblings() { # mk_siblings <dir> <good|bad>
  local d="$1" g="$2"
  mkdir -p "$d/homeassistant_frontend/src/panels/greenautarky-setup" "$d/homeassistant_frontend/src/data" "$d/supervisor/supervisor/plugins"
  if [ "$g" = good ]; then
    : > "$d/homeassistant_frontend/src/panels/greenautarky-setup/ga-setup-pin.ts"
    printf 'ota.greenautarky.com\ninflux.greenautarky.com\nloki.greenautarky.com\n_load_ga_services_ip\n_load_ga_ota_ip\n' > "$d/supervisor/supervisor/plugins/dns.py"
  else
    printf 'nothing\n' > "$d/supervisor/supervisor/plugins/dns.py"       # frontend: no ga-setup-pin.ts
  fi
}

echo "unset / empty / missing:"
run unset || true
has "$W/unset.out" 'NOTE: GA_SIBLING_REPOS is not set' && ok "unset: a loud NOTE names the variable" || bad "unset: no NOTE"
for id in 'SRC-14a\.\.c' 'BLD-SUP-DNS-a\.\.c' 'INT-05'; do
  has "$W/unset.out" "SKIP.* ${id} " && ok "unset: $id is skipped (not judged)" || bad "unset: $id was not skipped"
done
mkdir -p "$W/empty"
run empty GA_SIBLING_REPOS="$W/empty" || true
has "$W/empty.out" 'SKIP.* BLD-SUP-DNS-a\.\.c ' && ok "empty dir: skipped, no fallback to any other location" || bad "empty dir: not skipped"
run missing GA_SIBLING_REPOS="$W/does-not-exist" || true
has "$W/missing.out" 'NOTE: GA_SIBLING_REPOS=.* is not a directory' && ok "missing dir: a loud NOTE" || bad "missing dir: no NOTE"

echo "must-pass (siblings right):"
mk_siblings "$W/good" good
run good GA_SIBLING_REPOS="$W/good" || true
has "$W/good.out" 'PASS +BLD-SUP-DNS-a:' && ok "BLD-SUP-DNS-a judged and PASSES" || bad "BLD-SUP-DNS-a did not pass"
has "$W/good.out" 'PASS +INT-05:' && ok "INT-05 judged and PASSES" || bad "INT-05 did not pass"
has "$W/good.out" 'PASS +SRC-14a:' && ok "SRC-14a judged and PASSES" || bad "SRC-14a did not pass"
! has "$W/good.out" 'NOTE: GA_SIBLING_REPOS' && ok "no NOTE when it is set" || bad "NOTE printed although set"

echo "must-flag (siblings wrong):"
mk_siblings "$W/bad" bad
run bad GA_SIBLING_REPOS="$W/bad" || true
has "$W/bad.out" 'FAIL +BLD-SUP-DNS-a:' && ok "BLD-SUP-DNS-a FAILS on a dns.py without the hostname" || bad "BLD-SUP-DNS-a did not fail"
has "$W/bad.out" 'FAIL +INT-05:' && ok "INT-05 FAILS" || bad "INT-05 did not fail"
has "$W/bad.out" 'FAIL +SRC-14a:' && ok "SRC-14a FAILS on a frontend without ga-setup-pin.ts" || bad "SRC-14a did not fail"

[ "$ran" -ge 13 ] || { echo "FAIL: only $ran cases"; exit 1; }
echo "$ran cases ran, $fails failed"; exit $((fails>0))
