#!/usr/bin/env bash
# k31-flash-via-remote1.sh — DRAFT
#
# Flash K31 with a BOSv1.2.x image. Same recipe as flash-bench-ihost,
# but K31 lives on remote1 (= Raspberry Pi 5 with RSH-A16 hub) instead
# of the laptop's local RSH-A10 hub.
#
# Topology (verified 2026-06-18):
#   - remote1.tailscale → ssh as user `thomas`
#   - A16 plug 13: K31 iHost USB-data + power (Rockchip 2207:110b enumerates)
#   - A16 plug 14: USB-SD-MUX (Linux Automation FAST SN 00048.00528)
#   - SD-MUX stable symlink: /dev/usb-sd-mux/id-00048.00528 → ../sg0
#   - NOPASSWD sudoers on remote1: usbsdmux, dd, xzcat, umount
#
# Usage:
#   ./k31-flash-via-remote1.sh <local-image-path>
#
# Where <local-image-path> is e.g.
#   /home/user/git/ha-operating-system/ga_output/images/bos_ihost-16.3.1.9_prod_<TS>.img.xz
#
# After this script exits successfully, K31 should boot from SD.
# First-boot:
#   - ga-bootstrap fires, registers with NetBird
#   - ga-addon-prime updates the baked addons to pinned versions
#   - K31 shows up in fleet-manager /api/fleet within ~3-5 min
#
# Then (separately, not in this script):
#   - Run ga-flasher-py from laptop against K31's NetBird IP for
#     remaining provisioning stages (HA onboarding, telegraf env,
#     ghcr creds, fleet-bundle.yaml, device-label, Tailscale).

set -euo pipefail

IMG="${1:?Usage: $0 <local-image-path>}"
[[ -f "$IMG" ]] || { echo "ERROR: image not found: $IMG" >&2; exit 1; }
[[ "$IMG" =~ \.img\.xz$ ]] || { echo "ERROR: expected .img.xz file" >&2; exit 1; }

# Stable symlink on remote1 — K31's SD goes through this MUX
MUX="/dev/usb-sd-mux/id-00048.00528"
# A16 plug 13 = K31 power (= cycled at end to boot the new image)
PLUG_K31=13
# K31's hostname pattern in fleet-manager — used for post-flash polling
DEVICE_PATTERN="KIB-SON-00000031"

IMG_BASE=$(basename "$IMG")
REMOTE_TMP="/tmp/$IMG_BASE"

ssh_remote1() { ssh -o ConnectTimeout=10 remote1 "$@"; }

echo "[1/8] verify remote1 reachable + MUX wired"
ssh_remote1 "ls -la $MUX" >/dev/null || { echo "MUX symlink missing on remote1" >&2; exit 2; }

echo "[2/8] copy image to remote1:/tmp ($IMG_BASE, $(du -h "$IMG" | cut -f1))"
scp -o ConnectTimeout=10 "$IMG" remote1:"$REMOTE_TMP"

echo "[3/8] power off K31 (= release the SD card)"
ssh_remote1 "sudo /usr/local/sbin/a16_port_power.sh $PLUG_K31 off"

echo "[4/8] switch MUX to host (= remote1 takes the SD)"
ssh_remote1 "sudo /usr/bin/usbsdmux $MUX off && sleep 1 && sudo /usr/bin/usbsdmux $MUX host && sleep 3"

echo "[5/8] identify SD block device on remote1"
SD_DEV=$(ssh_remote1 "lsblk -ndo NAME,VENDOR | awk '\$2 == \"LinuxAut\" { print \"/dev/\" \$1 }'")
[[ -n "$SD_DEV" ]] || { echo "couldn't find Linux Automation SD on remote1" >&2; exit 3; }
echo "  SD block device: $SD_DEV"

echo "[6/8] flash image to SD ($(du -h "$IMG" | cut -f1) compressed, ~9.7GB raw)"
ssh_remote1 "sudo /bin/umount ${SD_DEV}1 2>/dev/null; sudo /bin/umount ${SD_DEV}2 2>/dev/null; true"
ssh_remote1 "xzcat $REMOTE_TMP | sudo /usr/bin/dd of=$SD_DEV bs=4M conv=fsync iflag=fullblock status=progress && sync"

echo "[7/8] switch MUX to dut (= K31 takes the SD back) + clean up image"
ssh_remote1 "sudo /usr/bin/usbsdmux $MUX off && sleep 1 && sudo /usr/bin/usbsdmux $MUX dut && sleep 2"
ssh_remote1 "rm -f $REMOTE_TMP"

echo "[8/8] power K31 back on (= boot from SD)"
ssh_remote1 "sudo /usr/local/sbin/a16_port_power.sh $PLUG_K31 on"

echo
echo "K31 booting. Next steps (NOT in this script):"
echo "  1. Wait 3-5 min for ga-bootstrap to register K31 with NetBird"
echo "  2. Check fleet-manager: curl ... /api/fleet | jq '.devices[] | select(.id == \"$DEVICE_PATTERN\")'"
echo "  3. Once reachable, run ga-flasher-py against K31's NetBird IP"
echo "     for the remaining stages (50/65/68b/68c/69/70/72b)"
