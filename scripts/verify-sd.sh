#!/usr/bin/env bash
# verify-sd.sh — Verify or flash a GA OS image against an SD card
#
# Usage:
#   verify-sd.sh [OPTIONS] <image.img.xz> [device]
#
# Options:
#   --sha        Verify image SHA256 checksum (file integrity only, no SD needed)
#   --diff       Diff boot partition files between image and SD card
#   --flash      Flash image to SD card (DESTRUCTIVE)
#   --all        Run sha + diff + prompt for flash
#   --device     SD card device (default: /dev/mmcblk0)
#   --dry-run    Show what would be done without doing it
#
# Examples:
#   verify-sd.sh --sha image.img.xz
#   verify-sd.sh --diff image.img.xz /dev/mmcblk0
#   verify-sd.sh --flash image.img.xz /dev/mmcblk0
#   verify-sd.sh --all image.img.xz

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

_pass()  { echo -e "  ${GREEN}PASS${NC}  $*"; }
_fail()  { echo -e "  ${RED}FAIL${NC}  $*"; FAILURES=$((FAILURES+1)); }
_warn()  { echo -e "  ${YELLOW}WARN${NC}  $*"; }
_info()  { echo -e "  ${CYAN}INFO${NC}  $*"; }
_step()  { echo -e "\n${BOLD}=== $* ===${NC}"; }

FAILURES=0

# ── Argument parsing ──────────────────────────────────────────────────────────
DO_SHA=false; DO_DIFF=false; DO_FLASH=false; DRY_RUN=false
IMAGE=""; DEVICE="/dev/mmcblk0"

usage() {
  sed -n '/^# Usage/,/^$/p' "$0" | sed 's/^# \?//'
  exit 1
}

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha)     DO_SHA=true ;;
    --diff)    DO_DIFF=true ;;
    --flash)   DO_FLASH=true ;;
    --all)     DO_SHA=true; DO_DIFF=true; DO_FLASH=true ;;
    --device)  DEVICE="$2"; shift ;;
    --dry-run) DRY_RUN=true ;;
    --help|-h) usage ;;
    *.img.xz|*.img)
      IMAGE="$1" ;;
    /dev/*)
      DEVICE="$1" ;;
    *)
      echo "Unknown argument: $1"; usage ;;
  esac
  shift
done

[[ -z "$IMAGE" ]] && { echo "Error: no image file specified"; usage; }
[[ ! -f "$IMAGE" ]] && { echo "Error: image not found: $IMAGE"; exit 1; }
IMAGE="$(realpath "$IMAGE")"
IMGBASE="${IMAGE%.xz}"; IMGBASE="${IMGBASE%.img}"

echo -e "${BOLD}GA OS SD Card Verification${NC}"
echo "  Image:  $IMAGE"
echo "  Device: $DEVICE"
$DRY_RUN && echo -e "  ${YELLOW}DRY RUN — no changes will be made${NC}"

# ── Helper: decompress image to a temp file ───────────────────────────────────
TMPDIR_WORK=""
cleanup() { [[ -n "$TMPDIR_WORK" ]] && rm -rf "$TMPDIR_WORK"; true; }
trap cleanup EXIT

decompress_image() {
  if [[ -n "$TMPDIR_WORK" ]]; then return; fi  # already done
  if $DRY_RUN; then IMG_RAW="$IMAGE"; return; fi
  # Decompress to same directory as the image (avoids /tmp space issues).
  # Falls back to /tmp if the image directory is not writable.
  local img_dir
  img_dir="$(dirname "$IMAGE")"
  if [[ -w "$img_dir" ]]; then
    TMPDIR_WORK="$(mktemp -d "${img_dir}/verify-sd.XXXXXX")"
    _info "Decompressing image (needs ~6GB, writing to ${img_dir})…"
  else
    TMPDIR_WORK="$(mktemp -d /tmp/verify-sd.XXXXXX)"
    _info "Decompressing image (needs ~6GB, writing to /tmp)…"
  fi
  if [[ "$IMAGE" == *.xz ]]; then
    xzcat "$IMAGE" > "$TMPDIR_WORK/image.img"
  else
    cp "$IMAGE" "$TMPDIR_WORK/image.img"
  fi
  IMG_RAW="$TMPDIR_WORK/image.img"
}

# ── 1. SHA verification ───────────────────────────────────────────────────────
if $DO_SHA; then
  _step "SHA256 Checksum Verification"
  SHA_FILE="${IMAGE}.sha256"
  if [[ -f "$SHA_FILE" ]]; then
    EXPECTED_SHA="$(awk '{print $1}' "$SHA_FILE")"
    _info "Expected: $EXPECTED_SHA"
    _info "Computing SHA256 of $IMAGE…"
    ACTUAL_SHA="$(sha256sum "$IMAGE" | awk '{print $1}')"
    _info "Actual:   $ACTUAL_SHA"
    if [[ "$EXPECTED_SHA" == "$ACTUAL_SHA" ]]; then
      _pass "SHA256 matches .sha256 file"
    else
      _fail "SHA256 MISMATCH — image may be corrupt"
    fi
  else
    _warn "No .sha256 file found alongside image — computing only"
    sha256sum "$IMAGE"
  fi
fi

# ── 2. Boot partition diff ────────────────────────────────────────────────────
if $DO_DIFF; then
  _step "Boot Partition Diff (image vs SD card)"

  [[ ! -b "$DEVICE" ]] && { _fail "Device not found: $DEVICE"; exit 1; }

  # Find boot partition — label hassos-boot or first partition
  BOOT_PART=""
  for part in "${DEVICE}p1" "${DEVICE}1"; do
    if [[ -b "$part" ]]; then
      label="$(lsblk -no LABEL "$part" 2>/dev/null || true)"
      if [[ "$label" == "hassos-boot" ]] || [[ -z "$BOOT_PART" ]]; then
        BOOT_PART="$part"
        [[ "$label" == "hassos-boot" ]] && break
      fi
    fi
  done

  [[ -z "$BOOT_PART" ]] && { _fail "Cannot find boot partition on $DEVICE"; exit 1; }
  _info "Boot partition: $BOOT_PART ($(lsblk -no LABEL "$BOOT_PART" 2>/dev/null))"

  if $DRY_RUN; then
    _info "[dry-run] Would decompress image (~6GB) to $(dirname "$IMAGE")"
    _info "[dry-run] Would mount image boot partition (first GPT partition offset)"
    _info "[dry-run] Would mount $BOOT_PART and diff contents"
  else
    decompress_image
    # Use a real temp dir for mount points
    MNT_BASE="$(mktemp -d /tmp/verify-sd-mnt.XXXXXX)"
    trap 'sudo umount "$MNT_BASE/img" "$MNT_BASE/sd" 2>/dev/null; rm -rf "$MNT_BASE"; cleanup' EXIT
    MOUNT_IMG="$MNT_BASE/img"
    MOUNT_SD="$MNT_BASE/sd"
    mkdir -p "$MOUNT_IMG" "$MOUNT_SD"

    # Find offset of first partition in the image (sector 34 or per GPT)
    SECTOR_SIZE=512
    PART_START_SECTORS="$(partx -g -o START "$IMG_RAW" 2>/dev/null | head -1 | tr -d ' ')"
    OFFSET=$(( PART_START_SECTORS * SECTOR_SIZE ))
    _info "Boot partition image offset: $OFFSET bytes (sector $PART_START_SECTORS)"
    sudo mount -o ro,loop,offset="$OFFSET" "$IMG_RAW" "$MOUNT_IMG" 2>/dev/null || {
      _fail "Could not mount image boot partition (need sudo)"; exit 1
    }
    sudo mount -o ro "$BOOT_PART" "$MOUNT_SD" 2>/dev/null || {
      sudo umount "$MOUNT_IMG" 2>/dev/null; _fail "Could not mount $BOOT_PART (need sudo)"; exit 1
    }

    echo ""
    DIFF_OUT="$(diff -rq "$MOUNT_IMG" "$MOUNT_SD" 2>/dev/null || true)"
    if [[ -z "$DIFF_OUT" ]]; then
      _pass "Boot partition contents identical"
    else
      _warn "Boot partition differs (expected for new builds):"
      echo "$DIFF_OUT" | sed 's/^/    /'
    fi

    sudo umount "$MOUNT_IMG" "$MOUNT_SD" 2>/dev/null || true
  fi
fi

# ── 3. Flash ──────────────────────────────────────────────────────────────────
if $DO_FLASH || { ! $DO_FLASH && $DO_SHA && [[ $FAILURES -eq 0 ]]; } && false; then
  : # placeholder — flash is explicit only
fi

if $DO_FLASH; then
  _step "Flash Image to SD Card"
  [[ ! -b "$DEVICE" ]] && { _fail "Device not found: $DEVICE"; exit 1; }

  DEVICE_SIZE="$(lsblk -bno SIZE "$DEVICE" | head -1)"
  DEVICE_GB=$((DEVICE_SIZE / 1024 / 1024 / 1024))
  DEVICE_MODEL="$(lsblk -dno MODEL "$DEVICE" 2>/dev/null | xargs || echo "unknown")"
  echo ""
  echo -e "  ${RED}${BOLD}WARNING: This will ERASE ALL DATA on:${NC}"
  echo -e "    Device:  ${BOLD}$DEVICE${NC}  (${DEVICE_GB} GB, ${DEVICE_MODEL})"
  echo -e "    Image:   $(basename "$IMAGE")"
  echo ""

  if $DRY_RUN; then
    _info "[dry-run] Would run: xzcat '$IMAGE' | dd of='$DEVICE' bs=4M status=progress conv=fsync"
  else
    read -r -p "  Type YES to confirm flash: " CONFIRM
    if [[ "$CONFIRM" != "YES" ]]; then
      _warn "Flash cancelled"
    else
      _info "Flashing — do not remove the SD card…"
      if [[ "$IMAGE" == *.xz ]]; then
        xzcat "$IMAGE" | sudo dd of="$DEVICE" bs=4M status=progress conv=fsync
      else
        sudo dd if="$IMAGE" of="$DEVICE" bs=4M status=progress conv=fsync
      fi
      sudo sync
      _pass "Flash complete — safe to remove SD card"
    fi
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All checks passed${NC}"
else
  echo -e "${RED}${BOLD}$FAILURES check(s) failed${NC}"
  exit 1
fi
