#!/bin/bash
# synth-release-artefacts.sh OUT -- put MINIMAL SYNTHETIC release artefacts into a fixture build output, so the
# build checks that open them are judged by their REAL code instead of living in a pinned NOT_COVERED set
# (Odoo #1632; the real artefacts are hundreds of MB and signed):
#   images/boot.vfat      the SD image's boot partition: carries the FAT 8.3 alias of the ethernet-force marker
#   images/*.raucb        a squashfs holding boot.vfat (OTA variant, no marker) + manifest.raucm with
#                         [meta.ga] release= (the unsquashfs-readable part of a RAUC verity bundle; 4 KiB of
#                         trailing bytes stand for the signature/hash tree, which unsquashfs ignores as it does
#                         for a real bundle). NOT signed: RAUC-SIG-01 needs a keyring this repo has no key for;
#                         it is judged by tests/gates/rauc_sig_runner.
#   images/*.img.xz       a toy GPT image with the GA partition NAMES, both RAUC slot pairs identical and non-blank
#                         (what scripts/check-slot-pairs.sh reads)
# Mutations for the red proofs (env, all default off):
#   SYNTH_ETH_IN_BUNDLE=1  the bundle's boot.vfat carries the marker        -> BLD-ETH-01 must FAIL
#   SYNTH_NO_SD_MARKER=1   the SD boot.vfat lacks the marker (dead detector) -> BLD-ETH-01 must FAIL
#   SYNTH_RELEASE=X        manifest release differs from /etc/ga-release     -> RFLOOR-01 must FAIL
#   SYNTH_NO_META=1        manifest has no [meta.ga] release                 -> RFLOOR-01 must FAIL
#   SYNTH_IMG_BLANK1=1     slot pair 1 left empty (the pre-#349 layout)      -> IMG-01 must FAIL
set -eu
OUT="${1:?OUT}"
for t in mksquashfs sfdisk xz truncate dd; do command -v "$t" >/dev/null || { echo "synth: $t missing" >&2; exit 2; }; done
IMG="$OUT/images"; T="$(mktemp -d "${TMPDIR:-/tmp}/synth-XXXXXX")"; trap 'rm -rf "$T"' EXIT
rel="$(head -n 1 "$OUT/target/etc/ga-release" | tr -d '\r\n')"; [ -n "$rel" ] || { echo "synth: no /etc/ga-release in the fixture target" >&2; exit 2; }
MARK='GA-ETH~1  ga-ethernet-force'
{ echo "FAT-BOOT-SD"; [ -n "${SYNTH_NO_SD_MARKER:-}" ] || echo "$MARK"; head -c 4096 /dev/zero; } > "$IMG/boot.vfat"
mkdir -p "$T/b"
{ echo "FAT-BOOT-OTA"; [ -z "${SYNTH_ETH_IN_BUNDLE:-}" ] || echo "$MARK"; head -c 4096 /dev/zero; } > "$T/b/boot.vfat"
{ printf '[update]\ncompatible=ga-fixture\nversion=1\n\n[image.rootfs]\nfilename=rootfs.img\n\n'
  [ -n "${SYNTH_NO_META:-}" ] || printf '[meta.ga]\nrelease=%s\n' "${SYNTH_RELEASE:-$rel}"; } > "$T/b/manifest.raucm"
mksquashfs "$T/b" "$T/bundle" -quiet -noappend -no-progress >/dev/null 2>&1
head -c 4096 /dev/zero >> "$T/bundle"
n=0; for f in "$IMG"/*.raucb; do [ -e "$f" ] || continue; cp "$T/bundle" "$f"; touch "$f"; n=$((n+1)); done
[ "$n" -ge 1 ] || { echo "synth: the fixture has no .raucb to replace" >&2; exit 2; }
MiB=$((1024*1024)); I="$T/disk.img"; truncate -s $((16*MiB)) "$I"
sfdisk -q "$I" >/dev/null <<'GPT'
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
GPT
off() { sfdisk -J "$I" | python3 -c 'import json,sys; n=sys.argv[1]; print([p["start"] for p in json.load(sys.stdin)["partitiontable"]["partitions"] if p["name"]==n][0])' "$1"; }
( printf 'GAOS-KERNEL'; head -c 300000 /dev/zero | tr '\0' k ) > "$T/kernel.bin"
( printf 'GAOS-ROOTFS'; head -c 900000 /dev/zero | tr '\0' r ) > "$T/rootfs.bin"
put() { dd if="$2" of="$I" bs=512 seek="$(off "$1")" conv=notrunc status=none; }
put hassos-kernel0 "$T/kernel.bin"; put hassos-system0 "$T/rootfs.bin"
if [ -z "${SYNTH_IMG_BLANK1:-}" ]; then put hassos-kernel1 "$T/kernel.bin"; put hassos-system1 "$T/rootfs.bin"; fi
n=0; for f in "$IMG"/*.img.xz; do [ -e "$f" ] || continue; xz -c -T0 -3 "$I" > "$f"; n=$((n+1)); done
[ "$n" -ge 1 ] || { echo "synth: the fixture has no .img.xz to replace" >&2; exit 2; }
