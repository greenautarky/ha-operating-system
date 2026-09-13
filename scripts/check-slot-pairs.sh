#!/usr/bin/env bash
# check-slot-pairs.sh — both RAUC slot pairs of a PRODUCED disk image must carry
#                       identical, non-blank content.
#
# Usage: check-slot-pairs.sh <image.img | image.img.xz>
#
# Exit: 0 both pairs identical and non-blank
#       1 a pair differs, or a pair is blank (all zeros)
#       2 cannot judge — no GPT, a slot partition missing, tool or read error
#
# WHY THIS EXISTS
# ---------------
# Since #349 the genimage layouts write kernel.img and the rootfs image into
# BOTH slot pairs (hassos-kernel0/1, hassos-system0/1), so a freshly flashed
# device has a complete OS in its inactive slot. SRC-23 in the build suite
# asserts that the layout DECLARES an `image =` for the slot-1 partitions. That
# is the intention, and a check of the intention stays green while the
# artefact drifts: a genimage include that resolves to the wrong file, a
# variable that expands empty in one build mode, a partition that is written
# and then truncated. This reads the .img.xz the bake produced.
#
# What it measures: the primary GPT is parsed from the first 34 sectors (no
# sfdisk, no loop device, no root), the four slot partitions are located by
# NAME, and each is hashed in ONE sequential pass over the decompressed stream
# (the slot partitions all sit within the first ~700 MB, so a 9 GB image never
# has to touch a disk). A pair is identical when the two hashes match, and
# non-blank when that hash is not the hash of a zero-filled region of the same
# size — two empty partitions are identical too, and that must not pass.
#
# Deliberately independent of sfdisk/partx: the self-test
# (tests/gates/slot_pairs/selftest.sh) builds its fixtures WITH sfdisk, so
# the parser here is cross-validated against an independent GPT writer.
set -uo pipefail

IMG="${1:-}"
[[ -n "$IMG" ]] || { echo "usage: $0 <image.img|image.img.xz>" >&2; exit 2; }
[[ -f "$IMG" ]] || { echo "ERROR: $IMG: no such file" >&2; exit 2; }
for t in od sha256sum dd head; do
  command -v "$t" >/dev/null 2>&1 || { echo "ERROR: $t not available" >&2; exit 2; }
done
case "$IMG" in
  *.xz) command -v xz >/dev/null 2>&1 || { echo "ERROR: xz not available for $IMG" >&2; exit 2; } ;;
esac

# The decompressed image as a stream, from the beginning. xz stops on its own
# once the reader closes the pipe, so reading the first N bytes costs N bytes.
stream() {
  case "$IMG" in
    *.xz) xz -dc "$IMG" ;;
    *)    cat "$IMG" ;;
  esac
}

# Little-endian unsigned integer of $2 bytes (4 or 8) at byte offset $1 of $3.
le_uint() {
  local off="$1" n="$2" file="$3"
  od -An -v -t "u${n}" -j "$off" -N "$n" "$file" | tr -d ' \n'
}

# --- pass 1: the primary GPT ---------------------------------------------------
# LBA 0 = protective MBR, LBA 1 = GPT header, LBA 2..33 = 128 entries x 128 B.
SECTOR=512
GPT_BYTES=$((34 * SECTOR))
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
HDR="$WORK/gpt.bin"

stream 2>"$WORK/xz.err" | head -c "$GPT_BYTES" > "$HDR"
if [[ "$(stat -c %s "$HDR")" -lt "$GPT_BYTES" ]]; then
  echo "ERROR: could not read the first $GPT_BYTES bytes of $IMG ($(cat "$WORK/xz.err" 2>/dev/null))" >&2
  exit 2
fi
if [[ "$(head -c 8 <(tail -c +$((SECTOR + 1)) "$HDR"))" != "EFI PART" ]]; then
  echo "ERROR: no GPT signature at LBA 1 — this check reads GPT layouts only (mbr images name no partitions)" >&2
  exit 2
fi
ENT_LBA="$(le_uint $((SECTOR + 72)) 8 "$HDR")"
ENT_NUM="$(le_uint $((SECTOR + 80)) 4 "$HDR")"
ENT_SZ="$(le_uint $((SECTOR + 84)) 4 "$HDR")"
if [[ "$ENT_LBA" -lt 2 || "$ENT_SZ" -lt 128 || "$ENT_NUM" -lt 1 ]]; then
  echo "ERROR: implausible GPT header (entries at LBA $ENT_LBA, $ENT_NUM x $ENT_SZ B)" >&2
  exit 2
fi
# Entries beyond the 34 sectors read above would need a longer pass 1; every
# genimage/sfdisk layout keeps them at LBA 2 with 128 x 128 B.
if (( ENT_LBA * SECTOR + ENT_NUM * ENT_SZ > GPT_BYTES )); then
  echo "ERROR: GPT entry array extends past sector 34 (LBA $ENT_LBA, $ENT_NUM x $ENT_SZ B) — unsupported layout" >&2
  exit 2
fi

# name -> "first_lba last_lba"
declare -A PART
for ((i = 0; i < ENT_NUM; i++)); do
  off=$((ENT_LBA * SECTOR + i * ENT_SZ))
  # Type GUID all-zero = unused entry.
  type_hex="$(od -An -v -t x1 -j "$off" -N 16 "$HDR" | tr -d ' \n')"
  [[ "$type_hex" == "00000000000000000000000000000000" ]] && continue
  first="$(le_uint $((off + 32)) 8 "$HDR")"
  last="$(le_uint $((off + 40)) 8 "$HDR")"
  # 72 bytes of UTF-16LE; every name here is ASCII, so dropping the NUL high
  # bytes yields the string without an iconv dependency.
  name="$(dd if="$HDR" bs=1 skip=$((off + 56)) count=72 2>/dev/null | tr -d '\000')"
  [[ -n "$name" ]] || continue
  PART["$name"]="$first $last"
done

missing=""
for p in hassos-kernel0 hassos-kernel1 hassos-system0 hassos-system1; do
  [[ -n "${PART[$p]:-}" ]] || missing+="$p "
done
if [[ -n "$missing" ]]; then
  echo "ERROR: slot partition(s) not in the GPT: ${missing}(found: ${!PART[*]})" >&2
  exit 2
fi

# --- pass 2: hash the four regions in one sequential read ----------------------
# Regions in disk order; each is skip-to + hash from the same pipe, so the
# stream is read exactly once, up to the end of the last slot partition.
regions=()
for p in hassos-kernel0 hassos-kernel1 hassos-system0 hassos-system1; do
  read -r first last <<<"${PART[$p]}"
  regions+=("$((first * SECTOR)) $(((last - first + 1) * SECTOR)) $p")
done
mapfile -t regions < <(printf '%s\n' "${regions[@]}" | sort -n)

# 1 MiB blocks when everything is MiB-aligned (genimage align=1M), else sectors.
BS=$((1024 * 1024))
for r in "${regions[@]}"; do
  read -r roff rsize _ <<<"$r"
  (( roff % BS == 0 && rsize % BS == 0 )) || BS=$SECTOR
done

# dd is trusted for the bytes, never for the count: at EOF it exits 0 with a
# SHORT transfer and status=none hides it, so a truncated stream would hash
# partial regions and the gate would issue a confident verdict about bytes it
# never saw (the self-test's truncated-.xz case caught exactly that). Every
# transfer is therefore checked against dd's own "N+P records out" line.
dd_full() { # dd_full <blocks> <what> — dd <blocks> full blocks from stdin to stdout, or die
  local n="$1" what="$2" recs
  dd bs="$BS" count="$n" iflag=fullblock status=noxfer 2>"$WORK/dd.err"
  recs="$(sed -nE 's/^([0-9]+)\+([0-9]+) records out.*/\1+\2/p' "$WORK/dd.err")"
  if [[ "$recs" != "${n}+0" ]]; then
    echo "ERROR: short read ($what): dd transferred ${recs:-?} records, expected ${n}+0 of ${BS} B — the stream ended early" >&2
    return 1
  fi
}

declare -A SIZE HASH
pos=0
{
  for r in "${regions[@]}"; do
    read -r roff rsize rname <<<"$r"
    if (( roff < pos )); then
      echo "ERROR: overlapping partitions ($rname starts at $roff, stream already at $pos)" >&2
      exit 2
    fi
    if (( roff > pos )); then
      dd_full $(((roff - pos) / BS)) "skipping to $rname" >/dev/null || exit 2
    fi
    h="$(dd_full $((rsize / BS)) "$rname" | sha256sum | cut -d' ' -f1)"
    # dd_full's failure is behind the pipe; its marker is the missing records
    # line, re-checked here rather than trusting the pipeline status.
    grep -qE "^$((rsize / BS))\+0 records out" "$WORK/dd.err" || exit 2
    printf '%s %s %s %s\n' "$rname" "$roff" "$rsize" "$h"
    pos=$((roff + rsize))
  done
} < <(stream 2>/dev/null) > "$WORK/hashes" || exit 2

nlines="$(wc -l < "$WORK/hashes")"
if [[ "$nlines" -ne 4 ]]; then
  echo "ERROR: hashed $nlines of 4 slot regions — the stream ended early or a read failed" >&2
  cat "$WORK/hashes" >&2
  exit 2
fi
while read -r rname roff rsize h; do
  SIZE["$rname"]="$rsize"; HASH["$rname"]="$h"
  printf '  %-15s offset=%-11s size=%-10s sha256=%s\n' "$rname" "$roff" "$rsize" "${h:0:16}…"
done < "$WORK/hashes"

# --- verdict -----------------------------------------------------------------
zero_hash() { head -c "$1" /dev/zero | sha256sum | cut -d' ' -f1; }
rc=0
for pair in "hassos-kernel0 hassos-kernel1" "hassos-system0 hassos-system1"; do
  read -r a b <<<"$pair"
  if [[ "${SIZE[$a]}" != "${SIZE[$b]}" ]]; then
    echo "FAIL: $a (${SIZE[$a]} B) and $b (${SIZE[$b]} B) differ in SIZE — a pair must be interchangeable"
    rc=1; continue
  fi
  if [[ "${HASH[$a]}" != "${HASH[$b]}" ]]; then
    echo "FAIL: $a and $b differ in CONTENT — the inactive slot is not the OS the active slot boots"
    rc=1; continue
  fi
  if [[ "${HASH[$a]}" == "$(zero_hash "${SIZE[$a]}")" ]]; then
    echo "FAIL: $a and $b are BOTH BLANK (all zeros) — identical, but there is no OS in either"
    rc=1; continue
  fi
  echo "ok:   $a == $b (${SIZE[$a]} B, non-blank)"
done
if (( rc == 0 )); then
  echo "PASS: both RAUC slot pairs carry identical, non-blank content"
fi
exit "$rc"
