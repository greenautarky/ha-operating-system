#!/bin/bash
# push-ota.sh — Deploy OTA bundle to devices via NetBird VPN
#
# Two modes:
#   1. Upload to OTA server (for Supervisor pull-based updates)
#   2. Push directly to device(s) (for manual/canary updates)
#
# Usage:
#   # Upload to OTA server (devices pull via Supervisor)
#   ./scripts/push-ota.sh --server --raucb <path>
#
#   # Push to single device
#   ./scripts/push-ota.sh --device <netbird-ip> --raucb <path>
#
#   # Push to all devices (from NetBird peer list)
#   ./scripts/push-ota.sh --fleet --raucb <path>
#
# Options:
#   --raucb PATH         Path to .raucb bundle
#   --server             Upload to OTA server (ota.greenautarky.com)
#   --device IP          Push to single device
#   --fleet              Push to all NetBird peers with "kibson" in hostname
#   --dry-run            Show what would happen without executing
#   --no-reboot          Install but don't reboot
#   --version VER        Version string (auto-detected from bundle if omitted)
#
set -euo pipefail

RAUCB=""
MODE=""
DEVICE_IP=""
DRY_RUN=false
NO_REBOOT=false
VERSION=""
SSH_KEY="${SSH_KEY:-$HOME/Nextcloud2/GreenAutarky/security_store/HomeassistantGreen0.pem}"
SSH_PORT="${SSH_PORT:-22222}"
OTA_SERVER="${OTA_SERVER:-ota.greenautarky.com}"
OTA_SERVER_PATH="${OTA_SERVER_PATH:-/srv/ota/releases}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --raucb)     RAUCB="$2"; shift 2 ;;
    --server)    MODE="server"; shift ;;
    --device)    MODE="device"; DEVICE_IP="$2"; shift 2 ;;
    --fleet)     MODE="fleet"; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --no-reboot) NO_REBOOT=true; shift ;;
    --version)   VERSION="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

[[ -z "$RAUCB" ]] && { echo "ERROR: --raucb required"; exit 1; }
[[ ! -f "$RAUCB" ]] && { echo "ERROR: File not found: $RAUCB"; exit 1; }
[[ -z "$MODE" ]] && { echo "ERROR: specify --server, --device <ip>, or --fleet"; exit 1; }

# Auto-detect version from bundle
if [[ -z "$VERSION" ]]; then
  if command -v rauc >/dev/null 2>&1; then
    VERSION=$(rauc info "$RAUCB" 2>/dev/null | grep "Version:" | awk '{print $2}' | tr -d "'" || true)
  fi
  if [[ -z "$VERSION" ]]; then
    # Try to extract from filename (bos_ihost-16.3.1.1_prod_*.raucb)
    VERSION=$(basename "$RAUCB" | grep -oP '\d+\.\d+\.\d+\.\d+' || true)
  fi
  [[ -z "$VERSION" ]] && { echo "ERROR: Could not detect version. Use --version"; exit 1; }
fi

BUNDLE_SIZE=$(du -h "$RAUCB" | cut -f1)
echo "=============================================="
echo "  OTA Deployment"
echo "=============================================="
echo "  Bundle:   $(basename "$RAUCB") ($BUNDLE_SIZE)"
echo "  Version:  $VERSION"
echo "  Mode:     $MODE"
echo ""

SSH_CMD="ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSH_PORT -i $SSH_KEY"
SCP_CMD="scp -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P $SSH_PORT -i $SSH_KEY"

# --- Server mode: upload to OTA server ---
if [[ "$MODE" == "server" ]]; then
  # Expected filename for Supervisor: haos_ihost-{version}.raucb
  OTA_FILENAME="haos_ihost-${VERSION}.raucb"
  DEST_DIR="${OTA_SERVER_PATH}/${VERSION}"

  echo "Uploading to $OTA_SERVER:$DEST_DIR/$OTA_FILENAME"
  if $DRY_RUN; then
    echo "  [DRY RUN] Would upload $RAUCB → $OTA_SERVER:$DEST_DIR/$OTA_FILENAME"
  else
    $SSH_CMD root@$OTA_SERVER "mkdir -p $DEST_DIR"
    $SCP_CMD "$RAUCB" root@$OTA_SERVER:"$DEST_DIR/$OTA_FILENAME"
    echo "  Upload complete."
    echo ""
    echo "  OTA URL: https://$OTA_SERVER/releases/$VERSION/$OTA_FILENAME"
    echo ""
    echo "  Devices will auto-update when Supervisor checks stable.json."
    echo "  stable.json hassos.ihost must be '$VERSION' for update to trigger."
  fi
  exit 0
fi

# --- Device/Fleet mode: push directly ---
push_to_device() {
  local ip="$1"
  echo "--- Device: $ip ---"

  if $DRY_RUN; then
    echo "  [DRY RUN] Would push $RAUCB → $ip, install, reboot"
    return 0
  fi

  # Check device is reachable
  if ! $SSH_CMD root@$ip 'echo ok' >/dev/null 2>&1; then
    echo "  UNREACHABLE — skipping"
    return 1
  fi

  # Check current version
  local current_ver
  current_ver=$($SSH_CMD root@$ip 'grep VERSION_ID= /etc/os-release | cut -d= -f2' 2>/dev/null)
  echo "  Current: $current_ver → Target: $VERSION"

  if [[ "$current_ver" == "$VERSION" ]]; then
    echo "  Already on target version — skipping"
    return 0
  fi

  # Upload
  echo "  Uploading bundle ($BUNDLE_SIZE)..."
  $SCP_CMD "$RAUCB" root@$ip:/mnt/data/ota_update.raucb

  # Install
  echo "  Installing via RAUC..."
  if $SSH_CMD root@$ip 'rauc install /mnt/data/ota_update.raucb 2>&1 | tail -2; rm -f /mnt/data/ota_update.raucb'; then
    echo "  Install succeeded."
  else
    echo "  INSTALL FAILED"
    return 1
  fi

  # Reboot
  if $NO_REBOOT; then
    echo "  Skipping reboot (--no-reboot)"
  else
    echo "  Rebooting..."
    $SSH_CMD root@$ip 'reboot' 2>/dev/null || true
  fi
  echo ""
}

if [[ "$MODE" == "device" ]]; then
  push_to_device "$DEVICE_IP"

elif [[ "$MODE" == "fleet" ]]; then
  echo "Discovering NetBird peers with 'kibson' in hostname..."
  # Get device list from NetBird
  PEERS=$(netbird status 2>/dev/null | grep -i "kibson" | awk '{print $NF}' | grep -oE '100\.[0-9.]+' || true)

  if [[ -z "$PEERS" ]]; then
    echo "No NetBird peers found matching 'kibson'. Check 'netbird status'."
    exit 1
  fi

  echo "Found $(echo "$PEERS" | wc -l) device(s):"
  echo "$PEERS" | sed 's/^/  /'
  echo ""

  TOTAL=0; OK=0; FAIL=0; SKIP=0
  for ip in $PEERS; do
    TOTAL=$((TOTAL + 1))
    if push_to_device "$ip"; then
      OK=$((OK + 1))
    else
      FAIL=$((FAIL + 1))
    fi
  done

  echo "=============================================="
  echo "  Fleet OTA: $OK/$TOTAL succeeded, $FAIL failed"
  echo "=============================================="
fi
