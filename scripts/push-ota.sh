#!/bin/bash
# push-ota.sh — Deploy OTA bundle to devices via NetBird VPN
#
# Two modes:
#   1. Upload to OTA server (for Supervisor pull-based updates)
#   2. Push directly to device(s) (for manual/canary updates)
#
# Since BOSv1.2.18 + ga_manager 0.42.0 the `--device` mode is rarely
# needed: the fleet-manager `ota-update` job has a `rauc_install_via_host_service`
# flag that writes /share/ga-rauc-install-request from the addon
# container; the host's systemd path-unit catches the file change and
# fires the install — fleet-wide, without operator SSH. Use `--server`
# to upload the bundle (= prerequisite for both paths) and then dispatch
# the fleet-manager job. `--device` remains for:
#   (a) pre-BOSv1.2.18 devices that don't have the ga-rauc-install.path
#       watcher + .service + helper yet (= one-time fallback to get
#       them ONTO BOSv1.2.18 the first time; note: BOSv1.2.17 also
#       counts as pre-BOSv1.2.18 because the 0.41.0/1.2.17 attempt at
#       this mechanism via Supervisor /host/services/<svc>/start hit
#       a non-existent endpoint and was never functional),
#   (b) lab / bench iteration where you want to skip the OTA server hop,
#   (c) emergency recovery when fleet-manager or Supervisor is down.
#
# Usage:
#   # Upload to OTA server PROD slot (devices pull via Supervisor or the new
#   # host-service mode in ga_manager 0.41.0+)
#   ./scripts/push-ota.sh --server --raucb <path>
#
#   # Upload to a per-rc CANARY slot (releases/<ver>/<rc>/…) — pulled only by a
#   # targeted ota-update dispatch with the same ga_release; never touches prod
#   ./scripts/push-ota.sh --server --raucb <path> --ga-release BOSv1.2.21-rc19
#
#   # Push to single device (= one-time fallback for pre-BOSv1.2.17 hosts)
#   ./scripts/push-ota.sh --device <netbird-ip> --raucb <path>
#
#   # Push to all devices (from NetBird peer list)
#   ./scripts/push-ota.sh --fleet --raucb <path>
#
# Options:
#   --raucb PATH         Path to .raucb bundle
#   --server             Upload to ga-tools OTA path (devices pull from there)
#   --device IP          Push to single device (direct rauc install)
#   --fleet              Push to all NetBird peers with "kibson" in hostname
#   --dry-run            Show what would happen without executing
#   --no-reboot          Install but don't reboot (device mode)
#   --force              Install even if device is already on target version
#                        (useful for canary re-install of same-version dev iterations)
#   --version VER        Version string (auto-detected from bundle if omitted)
#   --ga-release LABEL   Stage to a per-rc canary slot releases/<ver>/<LABEL>/
#                        instead of the shared prod slot (server mode)
#
# Server mode notes (--server):
#   - SSH target is the ga-tools host alias (default: ga-tools_tailscale).
#     ota.greenautarky.com is HTTPS-only via Caddy and not SSH-able.
#   - Files are placed under /data/ota/releases/<version>/ (Caddy bind-mount).
#   - Generates a sidecar .sha256 file in the filename-only format:
#     "<sha>  <filename>\n" — devices verify against this.
#   - Existing bundle for the same version is moved to _archive/ with a
#     timestamp suffix (no overwrite without backup).
set -euo pipefail

RAUCB=""
MODE=""
DEVICE_IP=""
DRY_RUN=false
NO_REBOOT=false
FORCE=false
VERSION=""
GA_RELEASE=""
SSH_KEY="${SSH_KEY:-$HOME/Nextcloud2/GreenAutarky/security_store/HomeassistantGreen0.pem}"
SSH_PORT="${SSH_PORT:-22222}"
# OTA server: SSH target alias, NOT the public hostname.
# Post-Hetzner-migration (2026-06) the OTA server is ga-newhost, and
# ota.greenautarky.com is served by Caddy from the named volume
# caddy_caddy_data (mounted at /data in the container). The host-side path of
# that volume is /var/lib/docker/volumes/caddy_caddy_data/_data/ota, so we scp
# there directly. (The old ga-tools_tailscale target + /data/ota/releases was
# stale — /data/ota on the ga-newhost host is a DIFFERENT dir, not the served
# one.) A cleaner long-term fix is a bind-mount or `docker cp` into caddy.
# Override both via OTA_SSH_HOST / OTA_SERVER_PATH if your setup differs.
OTA_SSH_HOST="${OTA_SSH_HOST:-ga-newhost}"
OTA_SERVER_PATH="${OTA_SERVER_PATH:-/var/lib/docker/volumes/caddy_caddy_data/_data/ota/releases}"
# Display name used in URLs / log output (Caddy-served hostname)
OTA_PUBLIC_HOST="${OTA_PUBLIC_HOST:-ota.greenautarky.com}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --raucb)     RAUCB="$2"; shift 2 ;;
    --server)    MODE="server"; shift ;;
    --device)    MODE="device"; DEVICE_IP="$2"; shift 2 ;;
    --fleet)     MODE="fleet"; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --no-reboot) NO_REBOOT=true; shift ;;
    --force)     FORCE=true; shift ;;
    --version)   VERSION="$2"; shift 2 ;;
    --ga-release) GA_RELEASE="$2"; shift 2 ;;
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

# Device-side SSH (KIB-SON via NetBird, port 22222, with private key)
SSH_CMD="ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSH_PORT -i $SSH_KEY"
SCP_CMD="scp -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P $SSH_PORT -i $SSH_KEY"

# OTA-server SSH (ga-tools host alias — uses ~/.ssh/config, no port/key override)
OTA_SSH="ssh -o ConnectTimeout=15 $OTA_SSH_HOST"
OTA_SCP="scp -o ConnectTimeout=15"

# --- Server mode: upload to the OTA server ---
if [[ "$MODE" == "server" ]]; then
  # Expected filename for the device pull: haos_ihost-{version}.raucb
  OTA_FILENAME="haos_ihost-${VERSION}.raucb"
  # Without --ga-release: the shared per-HAOS-version PROD slot
  #   releases/<version>/haos_ihost-<version>.raucb  (Supervisor fleet auto-
  #   update pulls this on a real version bump — reserve it for prod releases).
  # With --ga-release: a per-rc CANARY slot
  #   releases/<version>/<ga_release>/haos_ihost-<version>.raucb  — pulled ONLY
  #   by a targeted ota-update dispatch that carries the same ga_release, so a
  #   canary build never occupies the prod slot. (ga-rauc-install falls back to
  #   the prod slot on a 404, so pre-per-rc hosts still resolve.)
  if [[ -n "$GA_RELEASE" ]]; then
    case "$GA_RELEASE" in
      *[!A-Za-z0-9.-]* | "") echo "ERROR: --ga-release must match [A-Za-z0-9.-]"; exit 1 ;;
    esac
    DEST_DIR="${OTA_SERVER_PATH}/${VERSION}/${GA_RELEASE}"
    echo "  Slot:     per-rc canary ($GA_RELEASE)"
  else
    DEST_DIR="${OTA_SERVER_PATH}/${VERSION}"
    echo "  Slot:     shared prod (releases/$VERSION)"
  fi
  REMOTE_PATH="$DEST_DIR/$OTA_FILENAME"
  REMOTE_SHA_PATH="$REMOTE_PATH.sha256"

  echo "Target: $OTA_SSH_HOST:$REMOTE_PATH"

  # Pre-compute local SHA (devices verify against the sidecar)
  echo "  Computing local SHA256..."
  LOCAL_SHA=$(sha256sum "$RAUCB" | awk '{print $1}')
  echo "  SHA256: $LOCAL_SHA"

  if $DRY_RUN; then
    echo "  [DRY RUN] Would:"
    echo "    1. ssh $OTA_SSH_HOST 'mkdir -p $DEST_DIR'"
    echo "    2. archive any existing $OTA_FILENAME under _archive/"
    echo "    3. scp $RAUCB → $OTA_SSH_HOST:$REMOTE_PATH"
    echo "    4. write sidecar $REMOTE_SHA_PATH with: $LOCAL_SHA  $OTA_FILENAME"
    echo "    5. verify remote SHA matches"
    exit 0
  fi

  # Step 1: ensure dir exists
  $OTA_SSH "mkdir -p '$DEST_DIR' '$DEST_DIR/_archive'"

  # Step 2: archive existing bundle if present (don't silently overwrite)
  TS=$(date +%Y-%m-%d-%H%M)
  EXISTING=$($OTA_SSH "test -f '$REMOTE_PATH' && echo yes || echo no" | tr -d '[:space:]')
  if [[ "$EXISTING" == "yes" ]]; then
    ARCHIVED_NAME="${OTA_FILENAME%.raucb}_pre-${TS}.raucb"
    echo "  Archiving existing bundle to _archive/$ARCHIVED_NAME"
    $OTA_SSH "mv '$REMOTE_PATH' '$DEST_DIR/_archive/$ARCHIVED_NAME'"
  fi

  # Step 3: upload bundle
  echo "  Uploading bundle ($BUNDLE_SIZE)..."
  $OTA_SCP "$RAUCB" "$OTA_SSH_HOST:$REMOTE_PATH"

  # Step 4: write SHA256 sidecar (filename-only format, devices verify against this)
  echo "  Writing SHA256 sidecar..."
  $OTA_SSH "printf '%s  %s\n' '$LOCAL_SHA' '$OTA_FILENAME' > '$REMOTE_SHA_PATH'"

  # Step 5: verify remote SHA matches what we uploaded
  echo "  Verifying remote SHA..."
  REMOTE_SHA=$($OTA_SSH "sha256sum '$REMOTE_PATH'" | awk '{print $1}')
  if [[ "$LOCAL_SHA" != "$REMOTE_SHA" ]]; then
    echo "  ERROR: SHA mismatch — local=$LOCAL_SHA remote=$REMOTE_SHA"
    exit 1
  fi
  echo "  SHA verified ✓"

  URL_SUBPATH="$VERSION"
  [[ -n "$GA_RELEASE" ]] && URL_SUBPATH="$VERSION/$GA_RELEASE"
  echo ""
  echo "  Public URL: https://$OTA_PUBLIC_HOST/releases/$URL_SUBPATH/$OTA_FILENAME"
  echo "  Sidecar:    https://$OTA_PUBLIC_HOST/releases/$URL_SUBPATH/$OTA_FILENAME.sha256"
  echo ""
  if [[ -n "$GA_RELEASE" ]]; then
    echo "  Per-rc canary slot — NOT auto-pulled by Supervisor. Dispatch"
    echo "  ota-update {ga_release:'$GA_RELEASE', rauc_install_via_host_service:true}"
    echo "  to the target cohort ONLY (see the canary-ota-roll skill)."
  else
    echo "  Prod slot — devices auto-update when Supervisor checks stable.json."
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
    if $FORCE; then
      echo "  Already on $VERSION — re-installing anyway (--force)"
    else
      echo "  Already on target version — skipping (use --force to re-install)"
      return 0
    fi
  fi

  # Upload
  echo "  Uploading bundle ($BUNDLE_SIZE)..."
  $SCP_CMD "$RAUCB" root@$ip:/mnt/data/ota_update.raucb

  # Install
  echo "  Installing via RAUC..."
  # The 2026-06-04 KIB-SON-6 attempt exposed a false-positive: the
  # previous form `rauc install ... | tail -2` made the pipeline exit
  # status track `tail`, which is always 0, so signature-verification
  # failures ("LastError: signature verification failed") were swallowed
  # and the script printed "Install succeeded" before silently rebooting
  # the device onto its old slot. Capture the full output and check both
  # the exit code AND the conventional rauc error markers.
  install_output=$($SSH_CMD root@$ip '
      rauc install /mnt/data/ota_update.raucb 2>&1
      ec=$?
      rm -f /mnt/data/ota_update.raucb
      exit $ec
  ')
  install_rc=$?
  echo "$install_output" | tail -5
  if [[ $install_rc -ne 0 ]] \
     || echo "$install_output" | grep -qE "LastError:|Installing .* failed|signature verification failed|Verify error"; then
    echo "  INSTALL FAILED (exit=$install_rc)"
    return 1
  fi
  echo "  Install succeeded."

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
