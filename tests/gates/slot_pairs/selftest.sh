#!/usr/bin/env bash
# =============================================================================
# selftest.sh — scripts/check-slot-pairs.sh must go RED on an image whose
#               second slot pair is empty, partial or different, and GREEN on
#               one whose pairs are identical. Proven on synthetic images.
# =============================================================================
# The gate reads the .img.xz a bake produced and asserts that hassos-kernel1 /
# hassos-system1 carry the same non-blank bytes as hassos-kernel0 /
# hassos-system0. Until 2026-08-19 (#349) every image left the second pair
# EMPTY, so the "must-fail" side here is exactly the layout that shipped for
# months — and SRC-23, which asserts the layout declaration, cannot see an
# artefact that drifts from it.
#
# Fixtures are built here, with sfdisk, at 1 MiB granularity: the gate parses
# the GPT on its own (no sfdisk, no loop device), so an independent writer
# cross-validates its parser. A hash printed by the gate is also compared with
# the hash of the bytes this script wrote, at the offset sfdisk reports — a
# gate that hashed the wrong region would compare two wrong regions and could
# still say "identical".
#
# must-pass is not padding: a gate that flags a correct image is overridden by
# reflex, which is a slower way of having no gate at all.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$ROOT/scripts/check-slot-pairs.sh"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=''; GRN=''; NC=''; }
fails=0; ran=0
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); ran=$((ran + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; ran=$((ran + 1)); }

[[ -x "$GATE" ]] || { echo "FATAL: $GATE missing or not executable"; exit 2; }
for t in sfdisk xz sha256sum dd truncate jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "FATAL: $t required to build fixtures"; exit 2; }
done

WORK="$(mktemp -d)"
# Guarded on BASHPID: under `set -u` an unbound variable inside a pipeline
# element exits THAT subshell, and bash runs the EXIT trap there — which deleted
# this directory out from under the parent the first time this file ran.
trap '[[ "$BASHPID" == "$$" ]] && rm -rf "$WORK"' EXIT
OUT=""; rc=""

MiB=$((1024 * 1024))

# The GA layout at toy scale: same partition NAMES and order as
# buildroot-external/genimage/partitions-os-gpt.cfg, 1 MiB aligned.
# sfdisk writes the GPT; content is written afterwards with dd.
mk_image() { # mk_image <path>
  truncate -s $((16 * MiB)) "$1"
  sfdisk -q "$1" >/dev/null <<'EOF'
label: gpt
unit: sectors
first-lba: 2048
name=hassos-boot,    size=1MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
name=hassos-kernel0, size=1MiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
name=hassos-system0, size=2MiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
name=hassos-kernel1, size=1MiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
name=hassos-system1, size=2MiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
name=hassos-bootstate, size=1MiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
name=hassos-overlay, size=1MiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
name=hassos-data,    size=2MiB, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
EOF
}
# Byte offset of a named partition, from sfdisk — the INDEPENDENT reading.
part_off() { # part_off <image> <name>
  sfdisk -J "$1" 2>/dev/null | jq -r --arg n "$2" '.partitiontable.partitions[] | select(.name == $n) | .start * 512'
}
# Write a "payload" (a header plus filler) into a partition; the rest stays
# zero, exactly as genimage leaves the tail of a partition whose image is
# smaller than the slot.
fill() { # fill <image> <name> <payload-file>
  dd if="$3" of="$1" bs=512 seek=$(( $(part_off "$1" "$2") / 512 )) conv=notrunc status=none
}

# Two distinct payloads, deterministic. Smaller than their partitions.
printf 'GAOS-KERNEL-SQUASHFS' > "$WORK/kernel.img"
head -c $((300 * 1024)) /dev/zero | tr '\000' 'k' >> "$WORK/kernel.img"
printf 'GAOS-ROOTFS-EROFS' > "$WORK/rootfs.img"
head -c $((900 * 1024)) /dev/zero | tr '\000' 'r' >> "$WORK/rootfs.img"
printf 'GAOS-ROOTFS-EROFS-OTHER-BUILD' > "$WORK/rootfs-other.img"
head -c $((900 * 1024)) /dev/zero | tr '\000' 'x' >> "$WORK/rootfs-other.img"

run_gate() { # run_gate <image> -> sets $rc and $OUT (no subshell: both must reach the caller)
  OUT="$("$GATE" "$1" 2>&1)"; rc=$?
}

echo "=== Gate self-test: check-slot-pairs ==="
echo "gate: ${GATE#"$ROOT"/}"
echo

echo "must-pass — a correct image must not be flagged:"
# identical pairs (post-#349)
IMG="$WORK/good.img"; mk_image "$IMG"
fill "$IMG" hassos-kernel0 "$WORK/kernel.img"; fill "$IMG" hassos-kernel1 "$WORK/kernel.img"
fill "$IMG" hassos-system0 "$WORK/rootfs.img"; fill "$IMG" hassos-system1 "$WORK/rootfs.img"
run_gate "$IMG"
if [[ "$rc" == 0 ]] && grep -q '^PASS:' <<<"$OUT"; then ok "identical pairs (.img): rc=0, PASS line"
else bad "identical pairs (.img): rc=$rc"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi

# The parser reads the RIGHT region: the hash the gate prints for kernel0
# must equal the hash of the bytes at sfdisk's offset, padded to the 1 MiB
# partition — computed here without the gate.
expect="$( { cat "$WORK/kernel.img"; head -c $((MiB - $(stat -c %s "$WORK/kernel.img"))) /dev/zero; } | sha256sum | cut -d' ' -f1)"
got="$(grep -E '^ *hassos-kernel0 ' <<<"$OUT" | sed -E 's/.*sha256=([0-9a-f]{16}).*/\1/')"
if [[ -n "$got" && "${expect:0:16}" == "$got" ]]; then ok "kernel0 hash matches the bytes at sfdisk's offset (GPT parser cross-validated)"
else bad "kernel0 hash mismatch: gate printed '${got:-<none>}', independent hash starts ${expect:0:16}"; fi

# the same image compressed — the path a bake actually produces
xz -k -T0 -3 "$IMG"
run_gate "$IMG.xz"
if [[ "$rc" == 0 ]]; then ok "identical pairs (.img.xz, streamed): rc=0"
else bad "identical pairs (.img.xz): rc=$rc"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi

echo
echo "must-fail — every way the second pair can be wrong:"
# pre-#349: slot 1 allocated but never written
IMG="$WORK/empty1.img"; mk_image "$IMG"
fill "$IMG" hassos-kernel0 "$WORK/kernel.img"; fill "$IMG" hassos-system0 "$WORK/rootfs.img"
run_gate "$IMG"
if [[ "$rc" == 1 ]] && grep -q 'hassos-kernel0 and hassos-kernel1 differ in CONTENT' <<<"$OUT" \
                    && grep -q 'hassos-system0 and hassos-system1 differ in CONTENT' <<<"$OUT"; then
  ok "slot 1 empty (the pre-#349 layout): rc=1, both pairs named"
else bad "slot 1 empty: rc=$rc"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi
PRE349_OUT="$OUT"

# a partial write: kernel1 present, system1 not
IMG="$WORK/partial.img"; mk_image "$IMG"
fill "$IMG" hassos-kernel0 "$WORK/kernel.img"; fill "$IMG" hassos-kernel1 "$WORK/kernel.img"
fill "$IMG" hassos-system0 "$WORK/rootfs.img"
run_gate "$IMG"
if [[ "$rc" == 1 ]] && grep -q '^ok:   hassos-kernel0 == hassos-kernel1' <<<"$OUT" \
                    && grep -q 'hassos-system0 and hassos-system1 differ' <<<"$OUT"; then
  ok "kernel pair identical, system1 empty: rc=1, only the system pair flagged"
else bad "partial: rc=$rc"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi

# slot 1 carries a DIFFERENT rootfs (another build)
IMG="$WORK/other.img"; mk_image "$IMG"
fill "$IMG" hassos-kernel0 "$WORK/kernel.img"; fill "$IMG" hassos-kernel1 "$WORK/kernel.img"
fill "$IMG" hassos-system0 "$WORK/rootfs.img"; fill "$IMG" hassos-system1 "$WORK/rootfs-other.img"
run_gate "$IMG"
if [[ "$rc" == 1 ]] && grep -q 'hassos-system0 and hassos-system1 differ in CONTENT' <<<"$OUT"; then
  ok "system1 holds a different rootfs: rc=1"
else bad "different rootfs: rc=$rc"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi

# both pairs blank: identical, and still wrong
IMG="$WORK/blank.img"; mk_image "$IMG"
run_gate "$IMG"
if [[ "$rc" == 1 ]] && grep -q 'BOTH BLANK' <<<"$OUT"; then
  ok "both pairs all zeros: rc=1 (identical is not enough)"
else bad "blank: rc=$rc"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi

echo
echo "cannot-judge — a broken input must be an error, never a pass:"
# no GPT at all
head -c $((4 * MiB)) /dev/zero > "$WORK/nogpt.img"
run_gate "$WORK/nogpt.img"
if [[ "$rc" == 2 ]]; then ok "no GPT: rc=2"
else bad "no GPT: rc=$rc (expected 2)"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi

# a slot partition missing from the table
truncate -s $((16 * MiB)) "$WORK/noslot.img"
sfdisk -q "$WORK/noslot.img" >/dev/null <<'EOF'
label: gpt
unit: sectors
first-lba: 2048
name=hassos-boot,    size=1MiB
name=hassos-kernel0, size=1MiB
name=hassos-system0, size=2MiB
name=hassos-data,    size=2MiB
EOF
run_gate "$WORK/noslot.img"
if [[ "$rc" == 2 ]] && grep -q 'hassos-kernel1' <<<"$OUT" && grep -q 'hassos-system1' <<<"$OUT"; then
  ok "slot-1 partitions absent from the GPT: rc=2, both named"
else bad "missing slot partitions: rc=$rc (expected 2)"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi

# a truncated .xz (a download that stopped): the stream ends before slot 1
xz -dc "$WORK/good.img.xz" | head -c $((4 * MiB)) | xz -T0 -3 > "$WORK/trunc.img.xz"
run_gate "$WORK/trunc.img.xz"
if [[ "$rc" == 2 ]]; then ok "stream ends before the last slot: rc=2, not a verdict"
else bad "truncated stream: rc=$rc (expected 2)"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi

echo
if (( ran < 10 )); then
  echo "ERROR: only $ran cases ran — the fixture set shrank, nothing was proven" >&2
  exit 2
fi
echo "$((ran - fails)) ok, $fails failed  ($ran cases)"
if (( fails == 0 )); then
  echo "The gate was shown to fire on the pre-#349 layout and on partial/different/blank pairs,"
  echo "to stay quiet on identical pairs (.img and .img.xz), and to refuse a verdict on broken input."
  echo
  echo "Verbatim gate output on the pre-#349 layout (the red proof):"
  printf '%s\n' "$PRE349_OUT" | sed 's/^/    /'
  exit 0
fi
exit 1
