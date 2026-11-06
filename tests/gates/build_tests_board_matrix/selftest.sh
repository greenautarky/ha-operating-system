#!/bin/bash
# build_tests_board_matrix -- run ALL build tests (tests/ga_tests/run_build_tests.sh, the LIVE runner)
# on a fixture build output of EVERY board in GA_BOARDS, so a build test that assumes one board
# (an arch, a machine, a defconfig, a pin file, a channel, a package one board lacks ...) fails on the
# PR, in seconds, instead of after a 75-90 minute bake (Odoo #1620: BOSv1.6.0-dev4, DSGW, four bakes,
# 318 builder minutes, one board-unaware test found per bake).
#
# FIXTURES (fixtures/<board>/): captured from the REAL bake artefacts on the builder by capture-fixture.py
#   ihost    BOSv1.6.0-rc3 (green bake, ga-ops run 42249841160, 2026-11-06)
#   dsgw210  BOSv1.6.0-dev4 (ga-ops run 42233089444, 2026-11-06 14:21) -- the last DSGW bake whose artefact
#            exists; its own WIFI-09 was red (no iw). RECONSTRUCTED by one file: fixtures/dsgw210/reconstruct.sh
#            adds usr/sbin/iw, the one thing #987 put into the image. Every other file is the real bake's.
#   Only the NETWORK is replaced (skopeo = registry, curl = channel files); the runner and every checker
#   it calls are the live ones.
#
# WHAT IT ASSERTS, per board
#   1. no test FAILs except NOT_COVERED: four checks that open a signed OTA bundle / the disk image
#      (BLD-ETH-01, IMG-01, RFLOOR-01, RAUC-SIG-01) cannot be fixtured (hundreds of MB, signed); their
#      code carries no board token (reviewed 2026-11-06) and they stay covered by the bake itself.
#   2. every test that PASSED in the real bake still PASSES (expected/<board>.pass = pinned from the real
#      bake log, not from this run): a test that quietly turned into a SKIP or vanished is red.
#   3. the SKIP set is exactly expected/<board>.skip (the build_board_skips.tsv rows + what the real bake
#      skipped): a new skip must be reviewed.
#   ENV_DEP tests look for a developer's checkout under /home/user/git (SRC-14..16, BLD-ADMIN, supervisor
#   DNS): PASS/SKIP on CI, anything on a laptop -- excluded, listed here, not hidden.
#   Then red proofs: the historical board-unaware bugs are re-introduced into a COPY of the runner and
#   the matrix must go red on the named test of the right board.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../../../scripts/lib/tree-paths.sh
. "$ROOT/scripts/lib/tree-paths.sh"
for t in jq python3 tar xz strings; do command -v "$t" >/dev/null || { echo "FATAL: $t missing"; exit 2; }; done
[ -d "$ROOT/haos/buildroot-external" ] || { echo "FATAL: haos submodule not checked out (git submodule update --init --depth 1 haos)"; exit 2; }
W="$(mktemp -d "${TMPDIR:-/tmp}/bm-XXXXXX")"; trap 'rm -rf "$W"' EXIT
fails=0; ran=0
ok()  { ran=$((ran+1)); echo "  ok    $1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); echo "  FAIL  $1"; }
NOT_COVERED='^(BLD-ETH-01|IMG-01|RFLOOR-01|RAUC-SIG-01)$'
ENV_DEP='^(SRC-1[456].*|BLD-ADMIN-0[1-4]|BLD-SUP-DNS-a\.\.c|INT-05)$'
ids() { "$HERE/ids.sh" "$1" < "$2"; }

declare -A LOG
for b in $GA_BOARDS; do
  [ -d "$HERE/fixtures/$b" ] && [ -r "$HERE/expected/$b.pass" ] \
    && ok "$b: has a matrix fixture and a pinned expectation" \
    || { bad "$b: is in GA_BOARDS but has no fixtures/$b + expected/$b.{pass,skip} -- add the board to the matrix (capture-fixture.py)"; continue; }
  LOG[$b]="$W/$b.out"
  "$HERE/run-board.sh" "$b" "$W/w-$b" > "${LOG[$b]}" 2>&1
  n="$(grep -cE '^ +(PASS|FAIL|SKIP) ' "${LOG[$b]}")"
  if [ "$n" -ge 300 ] && grep -q '^=== Build tests:' "${LOG[$b]}"; then ok "$b: the runner ran to its summary ($n verdicts)"
  else bad "$b: the runner did not finish or judged only $n tests (floor 300) -- tail: $(tail -n 3 "${LOG[$b]}" | tr '\n' '|' | cut -c1-300)"; continue; fi
  f="$(ids FAIL "${LOG[$b]}" | grep -vE "$NOT_COVERED|$ENV_DEP" || true)"
  [ -z "$f" ] && ok "$b: no test fails (outside NOT_COVERED / ENV_DEP)" || bad "$b: FAILS: $(echo $f)"
  for id in $(echo "$NOT_COVERED" | tr -d '^()$' | tr '|' ' '); do
    grep -qE "^ +FAIL +${id}[: ]" "${LOG[$b]}" || bad "$b: $id no longer fails on the fixture -- the fixture grew a bundle: move it out of NOT_COVERED"
  done
  lost="$(LC_ALL=C comm -23 "$HERE/expected/$b.pass" <(ids PASS "${LOG[$b]}") | tr '\n' ' ')"
  [ -z "$lost" ] && ok "$b: every test that passed in the real bake still passes ($(wc -l < "$HERE/expected/$b.pass") ids)" || bad "$b: passed in the real bake, not now: $lost"
  sk="$(LC_ALL=C diff <(ids SKIP "${LOG[$b]}" | grep -vE "$NOT_COVERED|$ENV_DEP") "$HERE/expected/$b.skip" | grep '^[<>]' | tr '\n' ' ')"
  [ -z "$sk" ] && ok "$b: the SKIP set is the pinned one" || bad "$b: SKIP set differs from expected/$b.skip: $sk"
done

# ---- isolation probe: a board's verdicts must not depend on ANOTHER board's directory --------------------
# Outcome comparison cannot see a test that judges the wrong board's FILE when both boards are fine (UBOOT-01
# read the iHost's uboot.config for the DSGW-210 and passed). So: run each board with the other boards'
# directories REMOVED from the source tree; every verdict must be unchanged. PROBE_TOLERATED iterate
# GA_BOARDS by design (they lint/scan every board; a missing directory is an error there, not a verdict).
PROBE_TOLERATED='^(UNITREF-01|CVE-SCAN-08|CVE-SCAN-09)$'
vmap() { grep -E '^ +(PASS|FAIL|SKIP) ' "$1" | sed -E 's/^ +(PASS|FAIL|SKIP) +([^ :(]+).*/\2 \1/' | LC_ALL=C sort -u; }
others() { local o="" x; for x in $GA_BOARDS; do [ "$x" = "$1" ] || o="$o $x"; done; echo "$o"; }
for b in $GA_BOARDS; do
  [ -n "${LOG[$b]:-}" ] || continue
  HIDE_BOARDS="$(others "$b")" "$HERE/run-board.sh" "$b" "$W/wi-$b" > "$W/iso-$b.out" 2>&1
  d="$(diff <(vmap "${LOG[$b]}") <(vmap "$W/iso-$b.out") | grep '^[<>]' | sed -E 's/^[<>] ([^ ]+) .*/\1/' | sort -u | grep -vE "$PROBE_TOLERATED" | tr '\n' ' ')"
  [ -z "$d" ] && ok "$b: isolation probe -- no verdict depends on another board's directory" || bad "$b: verdicts that depend on ANOTHER board's directory: $d"
done

# ---- red proofs: re-introduce the historical bugs into a COPY of the runner -------------------------
mutant() {  # <name> <perl substitution on the runner> -> $W/mut-<name>/ (a tree whose runner is the mutant)
  local d="$W/mut-$1" hide="^(\.git|tests" hb; mkdir -p "$d/tests/ga_tests"
  for hb in ${HIDE_BOARDS:-}; do hide="$hide|$(ga_board_var BOARD_DIR "$hb")"; done   # a probe hides them from the mutant's tree too
  for e in $(ls -A "$ROOT" | grep -vE "$hide)\$"); do ln -s "$ROOT/$e" "$d/$e"; done
  for e in $(ls -A "$ROOT/tests" | grep -vx ga_tests); do ln -s "$ROOT/tests/$e" "$d/tests/$e"; done
  for e in $(ls -A "$ROOT/tests/ga_tests" | grep -vx run_build_tests.sh); do ln -s "$ROOT/tests/ga_tests/$e" "$d/tests/ga_tests/$e"; done
  cp "$ROOT/tests/ga_tests/run_build_tests.sh" "$d/tests/ga_tests/run_build_tests.sh"
  perl -0pi -e "$2" "$d/tests/ga_tests/run_build_tests.sh"
  cmp -s "$ROOT/tests/ga_tests/run_build_tests.sh" "$d/tests/ga_tests/run_build_tests.sh" && { echo "MUTATION '$1' CHANGED NOTHING (the runner moved: update the mutation)" >&2; return 1; }
  echo "$d/tests/ga_tests/run_build_tests.sh"
}
expect_red() {  # <mutation name> <board> <test id> <other board that must stay green on that id>
  local r out
  r="$(mutant "$1" "$MUT")" || { bad "mutation $1: could not be applied"; return; }
  out="$(RUNNER="$r" "$HERE/run-board.sh" "$2" "$W/wm-$1-$2" 2>&1)"
  if echo "$out" | grep -qE "^ +FAIL +${3}[: ]"; then ok "red proof $1: $2 goes red on $3"; else bad "red proof $1: $2 did NOT go red on $3"; fi
  if [ -n "${4:-}" ]; then
    out="$(RUNNER="$r" "$HERE/run-board.sh" "$4" "$W/wm-$1-$4" 2>&1)"
    if echo "$out" | grep -qE "^ +PASS +${3}[: ]"; then ok "red proof $1: $4 stays green on $3 (the mutation is board-specific)"; else bad "red proof $1: $4 lost $3"; fi
  fi
}
# VER-09 (DSGW dev4, 2026-11-06): the Supervisor digest was asked for armv7 whatever the board
MUT='s/(SUP_GHCR_DIGEST="\$\(skopeo inspect )\$_RBT_SKOPEO_ARCH/$1--override-arch arm --override-variant v7/'
expect_red ver09-armv7 dsgw210 VER-09 ihost
# VER-07 (found BY this matrix, 2026-11-06): the Core digest was asked for armv7 whatever the board
MUT='s/(GHCR_DIGEST="\$\(skopeo inspect )\$_RBT_SKOPEO_ARCH/$1--override-arch arm --override-variant v7/'
expect_red ver07-armv7 dsgw210 VER-07 ihost
# VER-10 (dev4): the baked add-ons were judged as armv7 tarballs
MUT='s/--arch "\$\{ARCH:-\$_RBT_ARCH\}" 2>&1\)"/--arch armv7 2>&1)"/'
expect_red ver10-armv7 dsgw210 VER-10 ihost
# XVER-06/07 (dev4): the channel was read from the iHost defconfig, so a dev bake was compared with stable.json
MUT='s/_defcfg="\$\{SRC:\+\$_RBT_DEFCONFIG\}"/_defcfg="\${SRC:+\$SRC\/buildroot-ihost\/configs\/ga_ihost_full_defconfig}"/'
expect_red xver-channel dsgw210 XVER-06
# XVER-03 (dev4): the Core image was expected as the armv7 build
MUT='s/(\[\[ "\$CH_CORE_IMG" == ghcr\.io\/greenautarky\/home-assistant-)\$\{_RBT_ARCH\}/${1}armv7/'
expect_red xver03-armv7 dsgw210 XVER-03 ihost
# VER-05: the Core image name expected as armv7
MUT='s/(\[\[ "\$VER_IMGS_CORE" == ghcr.io\/greenautarky\/home-assistant-)\$\{_RBT_ARCH\}/${1}armv7/'
expect_red ver05-armv7 dsgw210 VER-05 ihost
# GAMCAP-01 (dev4): the ga_manager tar was looked up as armv7
MUT='s/GAMCAP_ARGS=\(--pins "\$ADDON_JSON" --arch "\$\{ARCH:-\$_RBT_ARCH\}"\)/GAMCAP_ARGS=(--pins "\$ADDON_JSON" --arch armv7)/'
expect_red gamcap-armv7 dsgw210 GAMCAP-01 ihost
# UBOOT-01 (found BY the isolation probe, 2026-11-06): judged the iHost's uboot.config on every board.
# Outcome-neutral on a fixture where both are fine, so the proof is on the probe, not on a verdict.
MUT='s/_ub_cfg="\$\{_cve_src\}\/\$\(ga_board_var BOARD_BASE[^\n]*\n/_ub_cfg="\${_cve_src}\/buildroot-ihost\/board\/sonoff\/ihost\/uboot.config"\n/'
if r="$(mutant uboot01-ihostfile "$MUT")" && r2="$(HIDE_BOARDS=ihost mutant uboot01-iso "$MUT")"; then
  RUNNER="$r" "$HERE/run-board.sh" dsgw210 "$W/wm-ub" > "$W/ub-base.out" 2>&1
  HIDE_BOARDS=ihost RUNNER="$r2" "$HERE/run-board.sh" dsgw210 "$W/wm-ub2" > "$W/ub-iso.out" 2>&1
  diff <(vmap "$W/ub-base.out") <(vmap "$W/ub-iso.out") | grep -q 'UBOOT-01' \
    && ok "red proof uboot01: the isolation probe catches a DSGW check reading the iHost's file" || bad "red proof uboot01: the probe did NOT catch it"
else bad "mutation uboot01: could not be applied"; fi
# WIFI-09 (dev4): an image without iw -- not a runner mutation, the fixture as it was captured
out="$(FIXTURE_NO_RECONSTRUCT=1 "$HERE/run-board.sh" dsgw210 "$W/wm-noiw" 2>&1)"
echo "$out" | grep -qE "^ +FAIL +WIFI-09[: ]" && ok "red proof wifi09: the DSGW image as captured (no iw) goes red on WIFI-09" || bad "red proof wifi09: no iw did NOT go red"
# the DSGW pin file read as the iHost's (ADDON_PINS left empty for non-ihost boards)
MUT='s/\[\[ "\$_RBT_BOARD" == ihost \]\] \|\| _RBT_PINS_REL=.*\n/_RBT_PINS_REL=""\n/'
expect_red pins-ihost dsgw210 VER-10 ihost

# ---- the fixtures are committed to a PUBLIC repo: nothing key- or hash-shaped but the fake values -----
leak=""
for b in $GA_BOARDS; do
  for a in ga_output synced; do
    tar -xJOf "$HERE/fixtures/$b/$a.tar.xz" 2>/dev/null | grep -aE '\$(6|y|5|2[aby])\$[A-Za-z0-9./$]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{30,}|gh[so]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}' \
      | grep -avE 'FIXTURE' | head -n 3
  done
done > "$W/leaks.txt"
# the three secrets the bake bakes into the image are the fixed fake values
for b in $GA_BOARDS; do
  sk="$(tar -xJOf "$HERE/fixtures/$b/ga_output.tar.xz" ga_output/target/usr/share/ga-netbird/setup-key 2>/dev/null)"
  [ "$sk" = "00000000-0000-4000-8000-000000000000" ] && ok "$b fixture: the NetBird setup key is the fake one" || bad "$b fixture: setup key is not the fake value"
  tar -xJOf "$HERE/fixtures/$b/ga_output.tar.xz" ga_output/target/etc/shadow 2>/dev/null | grep -aq '^root:\$6\$FIXTURE\$' \
    && ok "$b fixture: the root hash is the fake one" || bad "$b fixture: root hash is not the fake value"
done
[ ! -s "$W/leaks.txt" ] && ok "fixtures: no key/hash/token-shaped value" || { bad "fixtures: secret-shaped content:"; cut -c1-120 "$W/leaks.txt"; }

[ "$ran" -ge 33 ] || { echo "FAIL: only $ran cases ran (floor 33)"; exit 1; }
echo "$ran cases ran, $fails failed"; exit $((fails>0))
