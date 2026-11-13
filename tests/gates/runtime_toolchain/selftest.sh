#!/usr/bin/env bash
# =============================================================================
# selftest.sh — the runtime toolchain gate must go RED and GREEN on known inputs.
# =============================================================================
# Exercises the LIVE scripts/check-runtime-toolchain.py (never a copy of its
# rules) on synthetic image tars in the bake's layouts, plus the LIVE policy
# file and the LIVE ga_build.sh wiring. Odoo #1975, ADR-0044 Amendment 2026-11-12.
#
#   must-flag  (enforce, rc 1, and the message names the image + category):
#              gcc cc1; rustc; cmake; binutils ld; Go; a toolchain left in a lower
#              layer while an upper layer deletes something else; an expired
#              allowlist entry; an allowlisted image does not cover another one;
#              docker-archive layout; a toolchain behind the rc13 zstd empty layer
#   must-pass  (rc 0): clean image; toolchain removed by a whiteout; by an opaque
#              dir; allowlisted within its date; report mode (rc 0 but a loud
#              ::warning:: that says it would fail); look-alike paths (a doc file
#              called cc1, a python module called 'as', libgcc_s / libstdc++)
#   broken     (rc 2, in BOTH modes): zero tars; a corrupt tar; a missing layer
#              blob; wrong-shaped manifest/index JSON (never a crash = rc 1);
#              a multi-arch index without --arch; bad config (unknown mode,
#              missing file, entry without ticket)
#   arch       a multi-arch index is read for the board arch, not "first arm"
#   wiring     ga_build.sh calls this script with the live policy and turns rc 1
#              into a failed bake; the live policy parses.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$ROOT/scripts/check-runtime-toolchain.py"
POLICY="$ROOT/.runtime-toolchain-gate"
BUILD="$ROOT/scripts/ga_build.sh"
MK="$HERE/make_image.py"
TODAY=2026-11-12

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=''; GRN=''; NC=''; }
fails=0; ran=0
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }

[[ -f "$GATE" ]] || { echo "FATAL: $GATE missing"; exit 2; }
[[ -f "$POLICY" ]] || { echo "FATAL: $POLICY missing"; exit 2; }
command -v python3 >/dev/null || { echo "FATAL: python3 required"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

cfg() { # cfg MODE [allow lines...]
    local f="$WORK/cfg.$RANDOM"; { echo "mode $1"; shift; printf '%s\n' "$@"; } > "$f"; echo "$f"
}
img() { # img DIR FILE NAME FORMAT LAYERS...
    local d="$1"; shift; mkdir -p "$d"; python3 "$MK" "$d/$1" "${@:2}" || { echo "FATAL: fixture build failed"; exit 2; }
}
CLEAN_BASE="bin/sh,usr/lib/libgcc_s.so.1,usr/lib/libstdc++.so.6"

# run NAME EXPECT_RC CFG DIR [GREP...]: each GREP must appear in the output
run() {
    local name="$1" want="$2" c="$3" d="$4"; shift 4
    ran=$((ran + 1))
    local out rc
    out="$(python3 "$GATE" --image-tars "$d" --config "$c" --today "$TODAY" ${GATE_ARGS:-} 2>&1)"; rc=$?
    if [[ "$rc" != "$want" ]]; then bad "$name: rc=$rc, want $want"; printf '%s\n' "$out" | sed 's/^/        /' | tail -4; return; fi
    local g; for g in "$@"; do
        grep -qF -- "$g" <<<"$out" || { bad "$name: rc ok but output lacks '$g'"; printf '%s\n' "$out" | sed 's/^/        /' | tail -4; return; }
    done
    ok "$name"
}

ENF="$(cfg enforce)"
REP="$(cfg report)"
CORE_OK="$(cfg enforce 'allow home-assistant-armv7 2026-12-31 #1965 fixture')"
CORE_EXP="$(cfg enforce 'allow home-assistant-armv7 2026-11-01 #1965 fixture')"
CORE_EXP_REP="$(cfg report 'allow home-assistant-armv7 2026-11-01 #1965 fixture')"

echo "=== runtime toolchain gate: must-flag (enforce) ==="
d="$WORK/f1"; img "$d" a.tar ghcr.io/x/core-armv7:1 oci "$CLEAN_BASE" "usr/libexec/gcc/arm-linux-gnueabihf/14/cc1"
run "gcc cc1 in a layer" 1 "$ENF" "$d" "core-armv7" "(gcc;" "::error::"
d="$WORK/f2"; img "$d" a.tar ghcr.io/x/img-armv7:1 oci "$CLEAN_BASE" "usr/bin/rustc"
run "rustc" 1 "$ENF" "$d" "(rust;"
d="$WORK/f3"; img "$d" a.tar ghcr.io/x/img-armv7:1 oci "$CLEAN_BASE" "usr/local/bin/cmake"
run "cmake" 1 "$ENF" "$d" "(cmake;"
d="$WORK/f4"; img "$d" a.tar ghcr.io/x/img-armv7:1 oci "$CLEAN_BASE" "sym:usr/bin/ld,usr/bin/arm-linux-gnueabihf-ld.bfd"
run "binutils ld (symlink + triplet)" 1 "$ENF" "$d" "(binutils;"
d="$WORK/f5"; img "$d" a.tar ghcr.io/x/img-armv7:1 oci "$CLEAN_BASE" "usr/local/go/bin/go"
run "go toolchain" 1 "$ENF" "$d" "(go;"
d="$WORK/f6"; img "$d" a.tar ghcr.io/x/img-armv7:1 oci "$CLEAN_BASE" "usr/libexec/gcc/x/14/cc1plus,tmp/build.log" "tmp/.wh.build.log"
run "toolchain kept while an upper layer deletes something else" 1 "$ENF" "$d" "(gcc;"
d="$WORK/f7"; img "$d" a.tar ghcr.io/greenautarky/home-assistant-armv7:2026.10.4.4 oci "$CLEAN_BASE" "usr/bin/rustc"
run "expired allowlist entry" 1 "$CORE_EXP" "$d" "EXPIRED" "#1965"
d="$WORK/f8"; img "$d" core.tar ghcr.io/greenautarky/home-assistant-armv7:1 oci "$CLEAN_BASE" "usr/bin/rustc"
img "$d" other.tar ghcr.io/greenautarky/ga_other-armv7:1 oci "$CLEAN_BASE" "usr/bin/cmake"
run "allowlist covers only its own image" 1 "$CORE_OK" "$d" "ga_other-armv7" "ALLOWLISTED home-assistant-armv7"
d="$WORK/f9"; img "$d" a.tar ghcr.io/x/img-armv7:1 docker "$CLEAN_BASE" "usr/libexec/gcc/x/14/lto1"
run "docker-archive layout" 1 "$ENF" "$d" "(gcc;"
d="$WORK/f10"; img "$d" a.tar ghcr.io/x/img-armv7:1 oci-zstd-empty "$CLEAN_BASE" "usr/bin/cargo"
run "toolchain behind the rc13 zstd empty layer" 1 "$ENF" "$d" "(rust;"

echo "=== runtime toolchain gate: must-pass ==="
d="$WORK/p1"; img "$d" a.tar ghcr.io/x/img-armv7:1 oci "$CLEAN_BASE"
run "clean image" 0 "$ENF" "$d" "1 images inspected, 0 with a build toolchain"
d="$WORK/p2"; img "$d" a.tar ghcr.io/x/img-armv7:1 oci "$CLEAN_BASE" "usr/bin/cmake" "usr/bin/.wh.cmake"
run "toolchain deleted by a whiteout" 0 "$ENF" "$d" "0 with a build toolchain"
d="$WORK/p3"; img "$d" a.tar ghcr.io/x/img-armv7:1 oci "$CLEAN_BASE" "usr/libexec/gcc/x/14/cc1" "usr/libexec/gcc/,usr/libexec/gcc/.wh..wh..opq"
run "toolchain removed by an opaque dir" 0 "$ENF" "$d" "0 with a build toolchain"
d="$WORK/p4"; img "$d" a.tar ghcr.io/greenautarky/home-assistant-armv7:2026.10.4.4 oci "$CLEAN_BASE" "usr/bin/rustc"
run "allowlisted within its date" 0 "$CORE_OK" "$d" "ALLOWLISTED home-assistant-armv7" "#1965"
d="$WORK/p5"; img "$d" a.tar ghcr.io/x/img-armv7:1 oci "$CLEAN_BASE" "usr/bin/rustc"
run "report mode: rc 0, but loud" 0 "$REP" "$d" "::warning::REPORT MODE (would FAIL in enforce)" "0 blocking"
run "report mode: expired entry is loud, rc 0" 0 "$CORE_EXP_REP" "$WORK/f7" "::warning::REPORT MODE" "EXPIRED"
d="$WORK/p6"; img "$d" a.tar ghcr.io/x/img-armv7:1 oci "$CLEAN_BASE,usr/share/doc/gcc/cc1,usr/lib/python3/site-packages/as,usr/bin/assh,usr/bin/ldd,usr/lib/rustlib-notes"
run "look-alike paths are not a toolchain" 0 "$ENF" "$d" "0 with a build toolchain"
d="$WORK/p7"; img "$d" a.tar ghcr.io/x/img-armv7:1 oci-zstd-empty "$CLEAN_BASE"
run "rc13 zstd empty layer is read, not broken" 0 "$ENF" "$d" "1 images inspected"
d="$WORK/p8"; img "$d" a.tar ghcr.io/x/img-armv7:1 oci "$CLEAN_BASE"
run "unused allowlist entry is named" 0 "$CORE_OK" "$d" "NOTICE: allowlist entry home-assistant-armv7"

echo "=== runtime toolchain gate: broken = rc 2 in both modes ==="
mkdir -p "$WORK/b1"
run "zero tars (enforce)" 2 "$ENF" "$WORK/b1" "BROKEN"
run "zero tars (report)" 2 "$REP" "$WORK/b1" "BROKEN"
mkdir -p "$WORK/b2"; head -c 3000 /dev/urandom > "$WORK/b2/x.tar"
run "corrupt tar (report)" 2 "$REP" "$WORK/b2" "BROKEN"
d="$WORK/b3"; img "$d" a.tar ghcr.io/x/img-armv7:1 oci "$CLEAN_BASE"
python3 - "$d/a.tar" <<'PY'
import sys, tarfile, io, os
src = sys.argv[1]; tmp = src + ".new"
with tarfile.open(src) as a, tarfile.open(tmp, "w") as b:
    for m in a.getmembers():
        if m.name.startswith("blobs/") and a.extractfile(m).read(2) == b"\x1f\x8b":
            continue  # drop the layer blob the manifest names
        b.addfile(m, a.extractfile(m) if m.isfile() else None)
os.replace(tmp, src)
PY
run "layer blob missing (report)" 2 "$REP" "$d" "BROKEN" "not in the tar"
run "unknown mode" 2 "$(cfg warn)" "$WORK/p1" "BROKEN" "mode must be"
run "missing config" 2 "$WORK/nope.cfg" "$WORK/p1" "BROKEN" "not found"
# Wrong-shaped but valid JSON must be BROKEN (2), never a crash that exits 1 and
# reads as "ships a build toolchain" (Manager review 2026-11-12, repro: [1]).
for _shape in 'docker-manifest=[1]' 'docker-manifest=[{"Layers": 5}]' 'docker-manifest={}' 'oci-index={"manifests": [1]}' 'oci-index=[]'; do
  d="$WORK/shape.$RANDOM"; img "$d" a.tar ghcr.io/x/img-armv7:1 "$_shape"
  run "wrong-shaped manifest is BROKEN, not 1 (${_shape})" 2 "$REP" "$d" "BROKEN"
done
# An unexpected exception inside one tar (index.json that is not JSON) is
# caught PER TAR and names the tar — the first of two backstops.
d="$WORK/notjson"; img "$d" a.tar ghcr.io/x/img-armv7:1 'oci-index={not json'
run "unexpected exception in a tar is BROKEN and names the tar" 2 "$REP" "$d" "BROKEN" "a.tar: JSONDecodeError"
# The second backstop: guarded_main turns ANY escaped exception into rc 2.
ran=$((ran + 1))
_gm="$(python3 - "$GATE" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gate", sys.argv[1]); g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
def boom(): raise KeyError("escaped")
g.main = boom
rc = g.guarded_main(); print("RC", rc)
PY
)"
if grep -q "^RC 2$" <<<"$_gm" && grep -q "BROKEN: unexpected KeyError" <<<"$_gm"; then ok "guarded_main: an escaped exception is rc 2 + loud ::error::"
else bad "guarded_main does not turn an escaped exception into rc 2: $(tail -2 <<<"$_gm")"; fi
d="$WORK/ma"; img "$d" a.tar ghcr.io/x/img:1 oci-multiarch "$CLEAN_BASE" "usr/libexec/gcc/x/14/cc1"
GATE_ARGS="--arch armv7" run "multi-arch index: --arch armv7 reads the arm/v7 image" 1 "$ENF" "$d" "(gcc;"
GATE_ARGS="--arch aarch64" run "multi-arch index: --arch aarch64 reads the arm64 image, not 'first arm'" 0 "$ENF" "$d" "0 with a build toolchain"
run "multi-arch index without --arch is BROKEN" 2 "$REP" "$d" "BROKEN" "multi-arch"
run "allow entry without ticket" 2 "$(cfg enforce 'allow home-assistant-armv7 2026-12-31 fixture-no-ticket')" "$WORK/p1" "BROKEN" "ticket"

echo "=== runtime toolchain gate: live policy + ga_build.sh wiring ==="
ran=$((ran + 1))
out="$(python3 "$GATE" --image-tars "$WORK/p1" --config "$POLICY" --today "$TODAY" 2>&1)"; rc=$?
if [[ "$rc" == 0 ]] && grep -qE "Runtime toolchain gate \(mode=(report|enforce)\)" <<<"$out"; then ok "live .runtime-toolchain-gate parses ($(grep -oE 'mode=[a-z]+' <<<"$out"))"
else bad "live .runtime-toolchain-gate does not parse (rc=$rc): $(tail -2 <<<"$out")"; fi
# Wiring: run the REAL 11c block of ga_build.sh (cut out between its markers)
# with a stub gate, and assert what the bake does with each gate exit code.
# A text grep for "exit 1" was not enough: it found the BROKEN branch's exit
# and stayed green when the rc-1 branch did not abort (fault injection,
# 2026-11-12).
_block="$(awk '/^# 11c\) No baked container ships a build toolchain/{f=1} /^# Post-build integrity checks/{f=0} f' "$BUILD")"
ran=$((ran + 1))
if [[ -n "$_block" ]] && grep -qE 'check-runtime-toolchain\.py"? +--image-tars' <<<"$_block" && grep -q '\.runtime-toolchain-gate' <<<"$_block"; then
  ok "ga_build.sh 11c calls the gate with the live policy"
else
  bad "ga_build.sh has no 11c block calling check-runtime-toolchain.py --image-tars with .runtime-toolchain-gate (the gate would be unreachable)"
fi
wire() { # wire NAME STUB_RC WANT_RC MUST_SAY [MUST_NOT_SAY]
  ran=$((ran + 1))
  local w="$WORK/wire.$2"; mkdir -p "$w/repo/scripts" "$w/out/build/hassio-1.0.0/images" "$w/out/images/reports"
  printf 'BR2_PACKAGE_HASSIO_ARCH="aarch64"\n' > "$w/out/.config"
  printf '#!/usr/bin/env python3\nimport sys; print("stub gate argv", " ".join(sys.argv[1:])); sys.exit(%s)\n' "$2" > "$w/repo/scripts/check-runtime-toolchain.py"
  local rc
  ( set -e; OUT="$w/out"; SCRIPT_DIR="$w/repo/scripts"; MODE=full; BOARD=fixture; eval "$_block" ) >"$w/log" 2>&1; rc=$?
  if [[ "$rc" != "$3" ]]; then bad "$1: bake rc=$rc, want $3"; sed 's/^/        /' "$w/log" | tail -3; return; fi
  if ! grep -qF -- "$4" "$w/log"; then bad "$1: bake log lacks '$4'"; sed 's/^/        /' "$w/log" | tail -3; return; fi
  if [[ -n "${5:-}" ]] && grep -qF -- "$5" "$w/log"; then bad "$1: bake log says '$5' (wrong branch)"; return; fi
  ok "$1"
}
# rc 1 and rc 2 must take DIFFERENT branches: a crash must never read as
# "ships a build toolchain" (mutation "-eq 1 branch neutered" survived before).
wire "bake continues when the gate passes (rc 0), board arch passed on" 0 0 "--arch aarch64"
wire "bake aborts with the TOOLCHAIN message on rc 1" 1 1 "ships a build toolchain that no allowlist entry covers" "is BROKEN"
wire "bake aborts with the BROKEN message on rc 2" 2 1 "runtime toolchain gate is BROKEN" "ships a build toolchain that no allowlist entry covers"

# End to end on the bake's own call path: the REAL 11c block running the REAL
# gate (not a stub) over image tars, with a policy file in the repo-root slot
# 11c reads. Proves that report mode CANNOT block a bake even on a finding no
# allowlist covers (red fixture), that a clean image passes (green fixture),
# and — so neither green is the gate being inert — that the same finding
# aborts the bake in enforce mode (Manager, 2026-11-13; rules 6/45).
real_bake() { # real_bake NAME MODE IMAGE_LAYER WANT_RC MUST_SAY
  ran=$((ran + 1))
  local w="$WORK/real.$RANDOM"; mkdir -p "$w/repo/scripts" "$w/out/build/hassio-1.0.0/images" "$w/out/images/reports"
  cp "$GATE" "$w/repo/scripts/check-runtime-toolchain.py"
  printf 'mode %s\n' "$2" > "$w/repo/.runtime-toolchain-gate"
  printf 'BR2_PACKAGE_HASSIO_ARCH="armv7"\n' > "$w/out/.config"
  python3 "$MK" "$w/out/build/hassio-1.0.0/images/x.tar" ghcr.io/x/fixture-armv7:1 oci "$CLEAN_BASE" "$3" \
    || { bad "$1: fixture build failed"; return; }
  local rc
  ( set -e; OUT="$w/out"; SCRIPT_DIR="$w/repo/scripts"; MODE=full; BOARD=fixture; eval "$_block" ) >"$w/log" 2>&1; rc=$?
  if [[ "$rc" != "$4" ]]; then bad "$1: bake rc=$rc, want $4"; sed 's/^/        /' "$w/log" | tail -3; return; fi
  if ! grep -qF -- "$5" "$w/log"; then bad "$1: bake log lacks '$5'"; sed 's/^/        /' "$w/log" | tail -3; return; fi
  if [[ ! -s "$w/out/images/reports/runtime-toolchain.json" ]]; then bad "$1: no summary json in the bake's reports dir"; return; fi
  ok "$1"
}
real_bake "real 11c + real gate, REPORT, unallowlisted toolchain: bake continues (red fixture)" report \
  "usr/libexec/gcc/arm-linux-gnueabihf/14/cc1" 0 "::warning::REPORT MODE (would FAIL in enforce)"
real_bake "real 11c + real gate, REPORT, clean image: bake continues (green fixture)" report \
  "usr/bin/env" 0 "0 with a build toolchain"
real_bake "real 11c + real gate, ENFORCE, same toolchain: bake ABORTS (the gate is not inert)" enforce \
  "usr/libexec/gcc/arm-linux-gnueabihf/14/cc1" 1 "ships a build toolchain that no allowlist entry covers"

echo
echo "runtime toolchain gate selftest: ${ran} checks, ${fails} failed"
[[ "$ran" -ge 44 ]] || { echo "FATAL: only ${ran} checks ran — the selftest lost coverage"; exit 2; }
[[ "$fails" -eq 0 ]]
