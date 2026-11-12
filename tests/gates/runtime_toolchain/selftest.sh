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
#              blob; bad config (unknown mode, missing file, entry without ticket)
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
    out="$(python3 "$GATE" --image-tars "$d" --config "$c" --today "$TODAY" 2>&1)"; rc=$?
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
wire() { # wire NAME STUB_RC WANT_RC
  ran=$((ran + 1))
  local w="$WORK/wire.$2"; mkdir -p "$w/repo/scripts" "$w/out/build/hassio-1.0.0/images" "$w/out/images/reports"
  printf '#!/usr/bin/env python3\nimport sys; print("stub gate rc %s"); sys.exit(%s)\n' "$2" "$2" > "$w/repo/scripts/check-runtime-toolchain.py"
  local rc
  ( set -e; OUT="$w/out"; SCRIPT_DIR="$w/repo/scripts"; MODE=full; BOARD=fixture; eval "$_block" ) >"$w/log" 2>&1; rc=$?
  if [[ "$rc" == "$3" ]]; then ok "$1"; else bad "$1: bake rc=$rc, want $3"; sed 's/^/        /' "$w/log" | tail -3; fi
}
wire "bake continues when the gate passes (rc 0)" 0 0
wire "bake aborts when the gate blocks (rc 1)" 1 1
wire "bake aborts when the gate is broken (rc 2)" 2 1

echo
echo "runtime toolchain gate selftest: ${ran} checks, ${fails} failed"
[[ "$ran" -ge 31 ]] || { echo "FATAL: only ${ran} checks ran — the selftest lost coverage"; exit 2; }
[[ "$fails" -eq 0 ]]
