#!/usr/bin/env bash
set -euo pipefail

# Load local secrets if present (do not commit scripts/local.env)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_ENV="${SCRIPT_DIR}/local.env"

if [[ -f "$LOCAL_ENV" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$LOCAL_ENV"
  set +a
  echo "Loaded local.env (ROOT_PW_HASH will be applied if set)."
else
  echo "No local.env found (ROOT_PW_HASH not set; root password unchanged)."
fi

# -----------------------------------------------------------------------------
# ga_build.sh — iHost Buildroot wrapper (container-safe)
#
# What it does:
#  1) Uses buildroot-ihost defconfig (external tree) + buildroot-external (your pkgs)
#  2) Builds full system with Buildroot's Go toolchain untouched (avoids containerd mismatch)
#  3) Disables Buildroot netbird package (because NetBird v0.60.x requires Go >= 1.24.10)
#  4) Builds NetBird standalone with Go 1.24.10 (SHA256-verified) and injects it into O/target
#  5) Writes build timestamp to /etc/ga-build-id and /etc/os-release in target rootfs
#  6) Ensures rel-ca.pem satisfies post-build expectation for dev-ca.pem (symlink/copy)
#  7) Re-finalizes target and rebuilds artifacts using 'all' (this tree has no 'images' target)
#  8) Renames output images with ga-build-id timestamp suffix (haos_ -> gaos_)
#  9) Creates provisioning image (factory image with embedded .img.xz)
# 10) Archives build configurations for reproducibility (see below)
# 11) Archives Buildroot legal-info (licenses) for compliance
# 12) Generates Software Bill of Materials (SBOM)
# 13) Saves complete build log with timestamps
#
# Reproducibility Features:
#   - Go tarball SHA256 verification before extraction
#   - Container images pinned by digest (not just tag)
#   - All Git repositories pinned by commit SHA
#   - All package tarballs tracked with hashes
#   - Host environment recorded (GCC, Make, Bash versions)
#
# Output Artifacts (in ${OUT}/images/):
#   - gaos_ihost-*.img.xz              Compressed disk image
#   - gaos_ihost-*.raucb               RAUC update bundle
#   - gaos_ihost-*_provisioning.img.xz Factory provisioning image
#   - sbom.json                        Software Bill of Materials
#   - build.log / build.log.xz         Complete build log
#   - configs/                         Build configuration archive:
#       - buildroot.config             Final Buildroot .config
#       - kernel.config                Final Linux kernel .config
#       - ga_ihost_full_defconfig      Original defconfig
#       - kernel-fragments/            Kernel config fragments
#       - device-tree/                 DTB files and DTS sources
#       - hardware-config-summary.txt  Hardware subsystem config extract
#       - uboot.config                 U-Boot bootloader config (if present)
#       - source-pins.json             Git SHAs and tarball hashes
#       - container-images.lock        Container digests lockfile
#       - container-images.lock.json   Container digests (JSON)
#       - MANIFEST.txt                 Archive manifest with checksums
#   - legal-info/                      License compliance archive:
#       - manifest.csv                 Package license manifest
#       - LICENSE-SUMMARY.txt          License summary
#       - legal-info-full.tar.xz       Complete legal-info archive
#
# Runtime Files (installed to target /etc/):
#   - /etc/ga-build-id                 Build timestamp
#   - /etc/os-release                  Extended with GA_BUILD_ID, GA_BUILD_TIMESTAMP
#   - /etc/ga-sbom.json                Software Bill of Materials
#   - /etc/ga-build/                   Build configs for runtime inspection
#       - source-pins.json
#       - hardware-config-summary.txt
#       - MANIFEST.txt
#       - LICENSE-SUMMARY.txt
#
# Usage:
#   ./scripts/ga_build.sh [full|partial|kernel|update] [dev|prod]
#   ./scripts/ga_build.sh dev       # shorthand for "update dev"
#   ./scripts/ga_build.sh prod      # shorthand for "update prod"
#
# Modes:
#   full    - Clean build from scratch (rm -rf $OUT)
#   partial - Rebuild with linux-dirclean and hassio-dirclean
#   kernel  - Rebuild with linux-dirclean only
#   update  - Incremental build (reconfigure only)
#   dev     - Shorthand for "update dev"
#   prod    - Shorthand for "update prod"
#
# Environment:
#   dev  (default) - Development build: fast, skips post-build artifacts
#                    (no SBOMs, no config archive, no provisioning image)
#   prod           - Production build: full artifacts for release
#                    (SBOMs, config archive, provisioning if enabled)
#
# Environment Variables (override defaults):
#   BUILDROOT_DIR    - Path to Buildroot source (default: /build/buildroot)
#   BR2EXT_IHOST     - Path to buildroot-ihost external tree (default: /build/buildroot-ihost)
#   BR2EXT_NETBIRD   - Path to buildroot-external tree (default: /build/buildroot-external)
#   OUT              - Output directory (default: /build/ga_output)
#   NETBIRD_TAG      - NetBird version tag (default: v0.64.4)
#   GO_VER           - Go version for NetBird build (default: 1.25.6)
#   GO_SHA256        - Expected SHA256 of Go tarball (for verification)
#   GA_BUILD_TIMESTAMP - Override build timestamp (default: auto-generated)
#   GA_ENV           - Environment stamp (default: from 2nd argument, or "dev")
#   GA_PROVISIONING  - Set to "true" to create provisioning image (default: false)
#   GA_LEGAL_INFO    - Set to "true" to generate legal-info archive (default: false)
#
# -----------------------------------------------------------------------------

unset BR2_EXTERNAL

MODE="${1:-full}"   # full | partial | kernel | update | dev | prod

# Shorthand: "dev" or "prod" as first arg => "update dev" or "update prod"
if [[ "$MODE" == "dev" || "$MODE" == "prod" ]]; then
  GA_ENV="$MODE"
  MODE="update"
else
  # Environment: 2nd argument overrides GA_ENV env var; default is "dev"
  if [[ -n "${2:-}" ]]; then
    GA_ENV="$2"
  fi
fi
GA_ENV="${GA_ENV:-dev}"
if [[ "$GA_ENV" != "dev" && "$GA_ENV" != "prod" ]]; then
  echo "ERROR: Invalid environment '$GA_ENV'. Must be 'dev' or 'prod'." >&2
  exit 1
fi
echo "Building with GA_ENV=$GA_ENV"

# ---- Paths inside container ----
BUILDROOT_DIR="${BUILDROOT_DIR:-/build/buildroot}"
BR2EXT_IHOST="${BR2EXT_IHOST:-/build/buildroot-ihost}"
BR2EXT_NETBIRD="${BR2EXT_NETBIRD:-/build/buildroot-external}"
BR2_EXTERNAL_PATH="${BR2EXT_IHOST}:${BR2EXT_NETBIRD}"

# Output dir (writable in container)
OUT="${OUT:-/build/ga_output}"
if [[ "$OUT" != /* ]]; then OUT="/build/${OUT}"; fi

# ---- NetBird standalone build settings ----
NETBIRD_TAG="${NETBIRD_TAG:-v0.64.4}"
GO_VER="${GO_VER:-1.25.6}"
# SHA256 checksum for Go tarball verification (from https://go.dev/dl/)
# Update this when changing GO_VER - get hash from https://go.dev/dl/
GO_SHA256="${GO_SHA256:-f022b6aad78e362bcba9b0b94d09ad58c5a70c6ba3b7582905fababf5fe0181a}"

# Systemd unit to install (from your external package tree)
NETBIRD_SERVICE_SRC="${NETBIRD_SERVICE_SRC:-${BR2EXT_NETBIRD}/package/netbird/netbird.service}"

# ---- CA files expected by post-build script ----
OTA_DIR="${OTA_DIR:-${BR2EXT_NETBIRD}/ota}"
REL_CA_PEM="${REL_CA_PEM:-${OTA_DIR}/rel-ca.pem}"
DEV_CA_PEM="${DEV_CA_PEM:-${OTA_DIR}/dev-ca.pem}"

echo "Using OUT=$OUT"
echo "Using BUILDROOT_DIR=$BUILDROOT_DIR"
echo "Using BR2EXT_DIR=$BR2EXT_NETBIRD"
echo "Using BR2_EXTERNAL=$BR2_EXTERNAL_PATH"
echo "Using NETBIRD_TAG=$NETBIRD_TAG"
echo "Using GO_VER=$GO_VER"
echo "Using OTA_DIR=$OTA_DIR"
echo "Using REL_CA_PEM=$REL_CA_PEM"
echo "Using DEV_CA_PEM=$DEV_CA_PEM"

# ---- Sanity checks (fail fast) ----
[[ -d "$BUILDROOT_DIR" ]] || { echo "ERROR: BUILDROOT_DIR not found: $BUILDROOT_DIR" >&2; exit 1; }
[[ -d "$BR2EXT_IHOST"  ]] || { echo "ERROR: BR2EXT_IHOST not found: $BR2EXT_IHOST" >&2; exit 1; }
[[ -d "$BR2EXT_NETBIRD" ]] || { echo "ERROR: BR2EXT_NETBIRD not found: $BR2EXT_NETBIRD" >&2; exit 1; }
[[ -f "$BR2EXT_IHOST/configs/ga_ihost_full_defconfig" ]] || {
  echo "ERROR: Defconfig not found: $BR2EXT_IHOST/configs/ga_ihost_full_defconfig" >&2
  exit 1
}
[[ -f "$NETBIRD_SERVICE_SRC" ]] || {
  echo "ERROR: netbird.service not found at: $NETBIRD_SERVICE_SRC" >&2
  exit 1
}
[[ -f "${BUILDROOT_DIR}/utils/config" ]] || {
  echo "ERROR: Buildroot utils/config not found at: ${BUILDROOT_DIR}/utils/config" >&2
  exit 1
}

ensure_dev_ca_from_rel_ca() {
  mkdir -p "$OTA_DIR"

  if [[ -f "$DEV_CA_PEM" ]]; then
    echo "dev-ca.pem present: $DEV_CA_PEM"
    return 0
  fi

  if [[ ! -f "$REL_CA_PEM" ]]; then
    echo "ERROR: rel-ca.pem not found at $REL_CA_PEM" >&2
    echo "Create it or place it there, otherwise post-build will fail." >&2
    exit 1
  fi

  # Prefer symlink; fallback to copy if symlink is not supported
  if ln -sf "$REL_CA_PEM" "$DEV_CA_PEM" 2>/dev/null; then
    echo "Created symlink: $DEV_CA_PEM -> $REL_CA_PEM"
  else
    cp -f "$REL_CA_PEM" "$DEV_CA_PEM"
    echo "Symlink failed; copied: $REL_CA_PEM -> $DEV_CA_PEM"
  fi
}

# Global build timestamp (compact format for filenames, set once at script start)
GA_BUILD_TIMESTAMP="${GA_BUILD_TIMESTAMP:-$(date '+%Y%m%d%H%M%S')}"

write_build_id_into_target() {
  local ts_human
  ts_human="$(date '+%F %T')"  # Human-readable local time for /etc/ga-build-id
  mkdir -p "${OUT}/target/etc"
  printf '%s\n' "$ts_human" > "${OUT}/target/etc/ga-build-id"
  echo "Wrote build id: $ts_human -> ${OUT}/target/etc/ga-build-id"

  # Stamp environment config into /etc/ga-env.conf
  local ga_env_conf="${OUT}/target/etc/ga-env.conf"
  local env_val="${GA_ENV:-dev}"
  local log_level="$([ "$env_val" = "prod" ] && echo "warning" || echo "debug")"
  local telemetry="$([ "$env_val" = "prod" ] && echo "minimal" || echo "verbose")"
  cat > "$ga_env_conf" <<ENVEOF
# GreenAutarky environment configuration
# Baked at build time — override at runtime via /mnt/data/ga-env.conf
#
# Values:
#   GA_ENV:        dev | prod
#   GA_LOG_LEVEL:  debug | info | warning
#   GA_TELEMETRY:  verbose | minimal | off

GA_ENV=${env_val}
GA_LOG_LEVEL=${log_level}
GA_TELEMETRY=${telemetry}
ENVEOF
  echo "Stamped GA_ENV=${env_val} (log=${log_level}, telemetry=${telemetry}) -> $ga_env_conf"

  # Append GA build info to /etc/os-release for easy identification
  local os_release="${OUT}/target/etc/os-release"
  if [[ -f "$os_release" ]]; then
    # Remove any previous GA entries to avoid duplicates on rebuilds
    sed -i '/^GA_BUILD_ID=/d; /^GA_BUILD_TIMESTAMP=/d; /^GA_ENV=/d' "$os_release"
    # Append new build info
    printf 'GA_BUILD_ID="%s"\n' "$ts_human" >> "$os_release"
    printf 'GA_BUILD_TIMESTAMP="%s"\n' "$GA_BUILD_TIMESTAMP" >> "$os_release"
    printf 'GA_ENV="%s"\n' "$env_val" >> "$os_release"
    echo "Appended GA build info to: $os_release"
  else
    echo "WARN: $os_release not found, skipping os-release update"
  fi
}

disable_buildroot_netbird() {
  local cfg="${OUT}/.config"
  if [[ ! -f "$cfg" ]]; then
    echo "WARN: $cfg not found; skipping netbird disable step."
    return 0
  fi

  echo "Disabling Buildroot netbird package (standalone NetBird will be injected later)..."

  "${BUILDROOT_DIR}/utils/config" --file "$cfg" \
    -d BR2_PACKAGE_NETBIRD \
    -d BR2_PACKAGE_HOST_NETBIRD || true

  make -C "$BUILDROOT_DIR" O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" olddefconfig

  # Clean any prior netbird build attempts
  make -C "$BUILDROOT_DIR" O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" netbird-dirclean || true
  rm -rf "$OUT/build/netbird-"* "$OUT/build/.netbird-"* 2>/dev/null || true

  # Show final state
  grep -E '^BR2_PACKAGE_NETBIRD=|^BR2_PACKAGE_HOST_NETBIRD=' "$cfg" || true
}

install_go_124_toolchain_for_standalone() {
  local tool_dir="${OUT}/host-tools/go${GO_VER}"

  if [[ -x "${tool_dir}/bin/go" ]]; then
    echo "Standalone Go already present: $("${tool_dir}/bin/go" version)"
    return 0
  fi

  local tgz="/tmp/go${GO_VER}.linux-amd64.tar.gz"
  local go_url="https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz"

  echo "Downloading standalone Go ${GO_VER}..."
  wget -O "$tgz" "$go_url"

  # Verify SHA256 checksum for reproducibility and security
  echo "Verifying Go tarball SHA256 checksum..."
  local actual_hash
  actual_hash="$(sha256sum "$tgz" | cut -d' ' -f1)"

  if [[ "$actual_hash" != "$GO_SHA256" ]]; then
    echo "ERROR: Go tarball SHA256 mismatch!" >&2
    echo "  Expected: $GO_SHA256" >&2
    echo "  Actual:   $actual_hash" >&2
    echo "  File:     $tgz" >&2
    echo "" >&2
    echo "This could indicate:" >&2
    echo "  - Corrupted download" >&2
    echo "  - Man-in-the-middle attack" >&2
    echo "  - GO_VER changed without updating GO_SHA256" >&2
    echo "" >&2
    echo "Get correct hash from: https://go.dev/dl/" >&2
    rm -f "$tgz"
    exit 1
  fi
  echo "Go tarball checksum verified: $actual_hash"

  echo "Installing standalone Go ${GO_VER} into ${tool_dir}..."
  rm -rf /tmp/go
  tar -C /tmp -xzf "$tgz"

  rm -rf "$tool_dir"
  mkdir -p "${OUT}/host-tools"
  mv /tmp/go "$tool_dir"

  # Keep tarball for archive_build_configs to record hash
  mkdir -p "${OUT}/host-tools"
  cp "$tgz" "${OUT}/host-tools/go${GO_VER}.linux-amd64.tar.gz"

  echo "Standalone Go installed: $("${tool_dir}/bin/go" version)"
}

build_and_install_netbird_standalone() {
  local tool_dir="${OUT}/host-tools/go${GO_VER}"
  local work="${OUT}/build/netbird-standalone-${NETBIRD_TAG}"

  rm -rf "$work"
  mkdir -p "$work"

  echo "Cloning NetBird ${NETBIRD_TAG}..."
  git clone --depth 1 --branch "${NETBIRD_TAG}" https://github.com/netbirdio/netbird.git "$work"

  echo "Building NetBird (ARMv7, CGO=0)..."
  (
    cd "$work"

    PATH="${tool_dir}/bin:${PATH}" \
    GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 \
    GOPROXY=https://proxy.golang.org,direct \
    GOTOOLCHAIN=local \
    go mod vendor

    mkdir -p "${work}/bin"

    # Embed the official release version into the binary (so "netbird version" is not "development").
    # NetBird expects the semver without the leading "v".
    NB_VERSION="${NETBIRD_TAG#v}"

    PATH="${tool_dir}/bin:${PATH}" \
    GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 \
    GOPROXY=https://proxy.golang.org,direct \
    GOTOOLCHAIN=local \
    go build -v -mod=vendor -trimpath -buildvcs=false \
      -ldflags "-s -w -X github.com/netbirdio/netbird/version.version=${NB_VERSION}" \
      -o "${work}/bin/netbird" ./client
  )

  echo "Injecting NetBird into target filesystem..."
  mkdir -p "${OUT}/target/usr/bin"
  install -m 0755 "${work}/bin/netbird" "${OUT}/target/usr/bin/netbird"

  # Install + enable systemd unit
  mkdir -p "${OUT}/target/etc/systemd/system" \
           "${OUT}/target/etc/systemd/system/multi-user.target.wants"
  install -m 0644 "${NETBIRD_SERVICE_SRC}" \
    "${OUT}/target/etc/systemd/system/netbird.service"
  ln -sf ../netbird.service \
    "${OUT}/target/etc/systemd/system/multi-user.target.wants/netbird.service"

  echo "NetBird injected:"
  file "${OUT}/target/usr/bin/netbird" || true
}

verify_outputs() {
  echo "=== Verify: Build outputs ==="

  echo "[1] Kernel config effective BT setting:"
  local kcfg
  kcfg="$(ls -d "${OUT}"/build/linux-*/.config 2>/dev/null | head -n 1 || true)"
  echo "Kernel .config: ${kcfg:-<not found>}"
  if [[ -n "${kcfg:-}" && -f "$kcfg" ]]; then
    grep -n -E '^(# )?CONFIG_BT' "$kcfg" || true
  fi

  echo
  echo "[2] Newest image artifacts:"
  find "${OUT}/images" -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 20 || true

  echo
  echo "[3] Hash key boot artifacts (if present):"
  for f in \
    "${OUT}/images/boot/linux" \
    "${OUT}/images/boot/zImage" \
    "${OUT}/images/boot/Image" \
    "${OUT}/images/boot/rv1109-sonoff-ihost.dtb" \
    "${OUT}/images/boot/rv1126-sonoff-ihost.dtb"
  do
    [[ -f "$f" ]] && sha256sum "$f"
  done

  echo
  echo "[4] Rootfs build-id (in target tree):"
  [[ -f "${OUT}/target/etc/ga-build-id" ]] && cat "${OUT}/target/etc/ga-build-id" || true

  echo "=== Verify: done ==="
}

rebuild_artifacts() {
  # Your tree has no 'images' target; use 'all' after target-finalize
  make -C "$BUILDROOT_DIR" O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" target-finalize
  make -C "$BUILDROOT_DIR" O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" -j"$(nproc)" all
}

# -----------------------------------------------------------------------------
# Archive build configurations and pin all sources
# -----------------------------------------------------------------------------

archive_build_configs() {
  echo "=== Archiving build configurations and source pinning ==="

  local cfg_dir="${OUT}/images/configs"
  local pins_file="${cfg_dir}/source-pins.json"
  rm -rf "$cfg_dir"
  mkdir -p "$cfg_dir"

  # -------------------------------------------------------------------------
  # 1) Buildroot configurations
  # -------------------------------------------------------------------------
  echo "[1/8] Archiving Buildroot configs..."

  # Final .config (resolved)
  if [[ -f "${OUT}/.config" ]]; then
    cp -v "${OUT}/.config" "${cfg_dir}/buildroot.config"
  fi

  # Original defconfig from external tree
  local defconfig_src="${BR2EXT_IHOST}/configs/${DEFCONFIG}"
  if [[ -f "$defconfig_src" ]]; then
    cp -v "$defconfig_src" "${cfg_dir}/${DEFCONFIG}"
  fi

  # -------------------------------------------------------------------------
  # 2) Kernel configurations
  # -------------------------------------------------------------------------
  echo "[2/8] Archiving Kernel configs..."

  # Final kernel .config
  local kernel_config
  kernel_config="$(ls -d "${OUT}"/build/linux-*/.config 2>/dev/null | head -n 1 || true)"
  if [[ -n "$kernel_config" && -f "$kernel_config" ]]; then
    cp -v "$kernel_config" "${cfg_dir}/kernel.config"
  fi

  # Kernel config fragments from external trees
  mkdir -p "${cfg_dir}/kernel-fragments"
  for ext_dir in "$BR2EXT_IHOST" "$BR2EXT_NETBIRD"; do
    if [[ -d "${ext_dir}/board" ]]; then
      find "${ext_dir}/board" -name "linux*.config" -o -name "*.config.fragment" 2>/dev/null | while read -r frag; do
        local rel_path="${frag#${ext_dir}/}"
        local dest_dir="${cfg_dir}/kernel-fragments/$(dirname "$rel_path")"
        mkdir -p "$dest_dir"
        cp -v "$frag" "$dest_dir/"
      done
    fi
  done

  # Kernel defconfig if referenced
  local kernel_defconfig
  kernel_defconfig="$(grep -E '^BR2_LINUX_KERNEL_DEFCONFIG=' "${OUT}/.config" 2>/dev/null | cut -d'"' -f2 || true)"
  if [[ -n "$kernel_defconfig" ]]; then
    echo "Kernel defconfig: $kernel_defconfig" > "${cfg_dir}/kernel-defconfig-name.txt"
  fi

  # -------------------------------------------------------------------------
  # 3) Device Tree Sources
  # -------------------------------------------------------------------------
  echo "[3/8] Archiving Device Tree files..."

  mkdir -p "${cfg_dir}/device-tree"

  # Copy DTB files with hashes
  for dtb in "${OUT}"/images/boot/*.dtb "${OUT}"/images/*.dtb; do
    if [[ -f "$dtb" ]]; then
      cp -v "$dtb" "${cfg_dir}/device-tree/"
      sha256sum "$dtb" >> "${cfg_dir}/device-tree/dtb-checksums.sha256"
    fi
  done

  # Find and copy DTS sources from kernel build
  local linux_dir
  linux_dir="$(ls -d "${OUT}"/build/linux-* 2>/dev/null | head -n 1 || true)"
  if [[ -n "$linux_dir" && -d "$linux_dir" ]]; then
    # Look for ihost/sonoff DTS files
    find "$linux_dir/arch/arm/boot/dts" -name "*ihost*" -o -name "*sonoff*" 2>/dev/null | while read -r dts; do
      cp -v "$dts" "${cfg_dir}/device-tree/" 2>/dev/null || true
    done
    # Also check external tree for custom DTS
    for ext_dir in "$BR2EXT_IHOST" "$BR2EXT_NETBIRD"; do
      find "$ext_dir" -name "*.dts" -o -name "*.dtsi" 2>/dev/null | while read -r dts; do
        local base
        base="$(basename "$dts")"
        cp -v "$dts" "${cfg_dir}/device-tree/${base}" 2>/dev/null || true
      done
    done
  fi

  # -------------------------------------------------------------------------
  # 4) Hardware configuration summary (CPU freq, WiFi, BT, USB, etc.)
  # -------------------------------------------------------------------------
  echo "[4/8] Generating hardware configuration summary..."

  local hw_summary="${cfg_dir}/hardware-config-summary.txt"
  local kernel_cfg="${cfg_dir}/kernel.config"

  {
    echo "=========================================="
    echo "Hardware Configuration Summary"
    echo "=========================================="
    echo "Build ID: ${GA_BUILD_TIMESTAMP}"
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    if [[ -f "$kernel_cfg" ]]; then
      echo "=== CPU / Power Management ==="
      { grep -E '^CONFIG_(CPU_FREQ|CPU_IDLE|ARM_|ROCKCHIP_|THERMAL|DEVFREQ)' "$kernel_cfg" 2>/dev/null || true; } | sort || echo "  (none found)"
      echo ""

      echo "=== WiFi / Wireless (cfg80211/mac80211) ==="
      { grep -E '^CONFIG_(CFG80211|MAC80211|WLAN|WIRELESS|NL80211|RFKILL)' "$kernel_cfg" 2>/dev/null || true; } | sort || echo "  (none found)"
      echo ""

      echo "=== WiFi Drivers ==="
      { grep -E '^CONFIG_(RTL|REALTEK|ATH|BRCM|MWIFIEX|MT7|MEDIATEK|SSV|ESP).*=' "$kernel_cfg" 2>/dev/null | { grep -iE 'wifi|wlan|80211|wireless' || true; } || \
      grep -E '^CONFIG_(RTL8|RTW8|WLAN_VENDOR)' "$kernel_cfg" 2>/dev/null || true; } | sort || echo "  (none found)"
      echo ""

      echo "=== Bluetooth ==="
      { grep -E '^CONFIG_(BT_|BT=|RFKILL)' "$kernel_cfg" 2>/dev/null || true; } | sort || echo "  (none found)"
      echo ""

      echo "=== USB ==="
      { grep -E '^CONFIG_(USB_OHCI|USB_EHCI|USB_XHCI|USB_DWC|USB_STORAGE|USB_SERIAL|USB_NET)' "$kernel_cfg" 2>/dev/null || true; } | sort || echo "  (none found)"
      echo ""

      echo "=== Storage (MMC/SD/eMMC) ==="
      { grep -E '^CONFIG_(MMC|SD_|SDIO)' "$kernel_cfg" 2>/dev/null || true; } | sort || echo "  (none found)"
      echo ""

      echo "=== Network (Ethernet) ==="
      { grep -E '^CONFIG_(NET_VENDOR|STMMAC|GMAC|ETH)' "$kernel_cfg" 2>/dev/null || true; } | head -30 | sort || echo "  (none found)"
      echo ""

      echo "=== I2C / SPI / GPIO ==="
      { grep -E '^CONFIG_(I2C_|SPI_|GPIO_|PINCTRL_).*=y' "$kernel_cfg" 2>/dev/null || true; } | head -30 | sort || echo "  (none found)"
      echo ""

      echo "=== Audio (ALSA/ASoC) ==="
      { grep -E '^CONFIG_(SND_SOC|SND_.*ROCKCHIP|AUDIO)' "$kernel_cfg" 2>/dev/null || true; } | sort || echo "  (none found)"
      echo ""

      echo "=== Video / Display / GPU ==="
      { grep -E '^CONFIG_(DRM_|FB_|VIDEO_|MALI|PANFROST|LIMA)' "$kernel_cfg" 2>/dev/null || true; } | head -30 | sort || echo "  (none found)"
      echo ""

      echo "=== Crypto / Security ==="
      { grep -E '^CONFIG_(CRYPTO_DEV|ROCKCHIP_CRYPTO|HW_RANDOM|TRUSTED|SECURITY)' "$kernel_cfg" 2>/dev/null || true; } | sort || echo "  (none found)"
      echo ""

      echo "=== Watchdog ==="
      { grep -E '^CONFIG_.*WATCHDOG' "$kernel_cfg" 2>/dev/null || true; } | sort || echo "  (none found)"
      echo ""

      echo "=== Kernel Version & Architecture ==="
      { grep -E '^CONFIG_(LOCALVERSION|ARM_|ARCH_|MACH_|SOC_)' "$kernel_cfg" 2>/dev/null || true; } | head -20 | sort || echo "  (none found)"
    else
      echo "(kernel.config not found - cannot extract hardware config)"
    fi

    echo ""
    echo "=== U-Boot Configuration ==="
    local uboot_cfg
    uboot_cfg="$(ls -d "${OUT}"/build/uboot-*/.config 2>/dev/null | head -n 1 || true)"
    if [[ -f "$uboot_cfg" ]]; then
      echo "U-Boot .config found: $uboot_cfg"
      echo ""
      echo "Key U-Boot settings:"
      grep -E '^CONFIG_(BOOTDELAY|BOOTCOMMAND|DEFAULT_FDT|SYS_BOARD|SYS_SOC|SPL|ENV_)' "$uboot_cfg" 2>/dev/null | head -20 || true
      # Also copy U-Boot config
      cp -v "$uboot_cfg" "${cfg_dir}/uboot.config" 2>/dev/null || true
    else
      echo "(U-Boot .config not found)"
    fi

    echo ""
    echo "=== Firmware Files (in target) ==="
    if [[ -d "${OUT}/target/lib/firmware" ]]; then
      echo "Firmware directory contents:"
      # Use subshell to isolate pipefail issues with head closing pipe early
      ( find "${OUT}/target/lib/firmware" -type f 2>/dev/null || true ) | head -50 | while read -r fw; do
        local fw_name="${fw#${OUT}/target}"
        local fw_size
        fw_size="$(stat -c%s "$fw" 2>/dev/null || echo "?")"
        echo "  ${fw_name} (${fw_size} bytes)"
      done || true
      echo ""
      echo "Total firmware files: $(find "${OUT}/target/lib/firmware" -type f 2>/dev/null | wc -l)"
    else
      echo "(no firmware directory found)"
    fi

    echo ""
    echo "=== Kernel Modules (in target) ==="
    if [[ -d "${OUT}/target/lib/modules" ]]; then
      local mod_dir
      mod_dir="$(ls -d "${OUT}"/target/lib/modules/* 2>/dev/null | head -n 1 || true)"
      if [[ -d "$mod_dir" ]]; then
        echo "Kernel version: $(basename "$mod_dir")"
        echo ""
        echo "WiFi/Wireless modules:"
        find "$mod_dir" -name "*.ko" 2>/dev/null | { grep -iE 'wifi|wlan|80211|wireless|cfg80211|mac80211|rtl|rtw|ath|brcm|mt7' || true; } | head -20 || echo "  (none)"
        echo ""
        echo "Bluetooth modules:"
        find "$mod_dir" -name "*.ko" 2>/dev/null | { grep -iE 'bluetooth|bt|hci' || true; } | head -10 || echo "  (none)"
        echo ""
        echo "Total modules: $(find "$mod_dir" -name "*.ko" 2>/dev/null | wc -l)"
      fi
    else
      echo "(no modules directory found)"
    fi

  } > "$hw_summary"

  echo "Hardware config summary created: $hw_summary"

  # Also copy to target for runtime inspection
  mkdir -p "${OUT}/target/etc/ga-build"
  cp "$hw_summary" "${OUT}/target/etc/ga-build/"

  # -------------------------------------------------------------------------
  # 5) Git repository pinning (all source trees)
  # -------------------------------------------------------------------------
  echo "[5/8] Pinning Git repositories..."

  local git_pins=""

  # Helper to get git info as JSON
  get_git_info() {
    local repo_path="$1"
    local repo_name="$2"
    local commit branch remote_url dirty

    if [[ -d "$repo_path/.git" ]] || git -C "$repo_path" rev-parse --git-dir &>/dev/null; then
      commit="$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || echo "unknown")"
      branch="$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
      remote_url="$(git -C "$repo_path" remote get-url origin 2>/dev/null || echo "unknown")"
      dirty="$(git -C "$repo_path" status --porcelain 2>/dev/null | wc -l)"
      cat <<GITEOF
    "${repo_name}": {
      "path": "${repo_path}",
      "commit": "${commit}",
      "branch": "${branch}",
      "remote": "${remote_url}",
      "dirty_files": ${dirty}
    }
GITEOF
    fi
  }

  # Collect git info for all relevant repos
  {
    echo "{"
    echo '  "generated": "'$(date '+%Y-%m-%dT%H:%M:%S')'",'
    echo '  "build_id": "'${GA_BUILD_TIMESTAMP}'",'
    echo '  "repositories": {'

    local first=true

    # Buildroot
    if [[ -d "$BUILDROOT_DIR" ]]; then
      [[ "$first" == "true" ]] || echo ","
      first=false
      get_git_info "$BUILDROOT_DIR" "buildroot"
    fi

    # External tree: ihost
    if [[ -d "$BR2EXT_IHOST" ]]; then
      [[ "$first" == "true" ]] || echo ","
      first=false
      get_git_info "$BR2EXT_IHOST" "buildroot-ihost"
    fi

    # External tree: netbird/external
    if [[ -d "$BR2EXT_NETBIRD" ]]; then
      [[ "$first" == "true" ]] || echo ","
      first=false
      get_git_info "$BR2EXT_NETBIRD" "buildroot-external"
    fi

    echo "  },"

    # -------------------------------------------------------------------------
    # 5) Tarball/download hashes from Buildroot
    # -------------------------------------------------------------------------
    echo "[6/8] Collecting package download hashes..." >&2

    echo '  "packages": ['

    # Parse Buildroot's download directory for all tarballs
    local dl_dir="${BUILDROOT_DIR}/dl"
    [[ -d "$dl_dir" ]] || dl_dir="${OUT}/dl"

    local pkg_first=true
    if [[ -d "$dl_dir" ]]; then
      # Find all .hash files and extract info
      # Use process substitution to avoid subshell variable scope issues
      while read -r hashfile; do
        local pkg_name
        pkg_name="$(basename "$(dirname "$hashfile")")"

        # Read hash file content (format: algo  hash  filename)
        while IFS= read -r line; do
          [[ "$line" =~ ^# ]] && continue
          [[ -z "$line" ]] && continue

          local algo hash filename
          read -r algo hash filename <<< "$line"
          [[ -z "$hash" ]] && continue

          [[ "$pkg_first" == "true" ]] || echo ","
          pkg_first=false

          cat <<PKGEOF
    {
      "package": "${pkg_name}",
      "filename": "${filename}",
      "algorithm": "${algo}",
      "hash": "${hash}"
    }
PKGEOF
        done < "$hashfile"
      done < <(find "$dl_dir" -name "*.hash" -type f 2>/dev/null | sort) || true
    fi

    # Also capture any packages built from git (check stamps)
    if [[ -d "${OUT}/build" ]]; then
      for stamp in "${OUT}"/build/*/.stamp_downloaded; do
        [[ -f "$stamp" ]] || continue
        local pkg_dir
        pkg_dir="$(dirname "$stamp")"
        local pkg_name
        pkg_name="$(basename "$pkg_dir")"

        # Check if it's a git checkout
        if [[ -d "${pkg_dir}/.git" ]]; then
          local pkg_commit
          pkg_commit="$(git -C "$pkg_dir" rev-parse HEAD 2>/dev/null || echo "unknown")"

          [[ "$pkg_first" == "true" ]] || echo ","
          pkg_first=false

          cat <<PKGEOF
    {
      "package": "${pkg_name}",
      "type": "git",
      "commit": "${pkg_commit}"
    }
PKGEOF
        fi
      done
    fi

    echo "  ],"

    # -------------------------------------------------------------------------
    # 6) Standalone tool versions
    # -------------------------------------------------------------------------
    echo "[7/8] Recording standalone tool versions..." >&2

    echo '  "standalone_tools": {'
    echo '    "go": {'
    echo '      "version": "'${GO_VER}'",'
    echo '      "download_url": "https://go.dev/dl/go'${GO_VER}'.linux-amd64.tar.gz",'

    # Calculate expected hash if we have the file
    local go_hash="unknown"
    local go_tgz="${OUT}/host-tools/go${GO_VER}.tar.gz"
    [[ -f "$go_tgz" ]] && go_hash="$(sha256sum "$go_tgz" | cut -d' ' -f1)"
    # Try /tmp as fallback
    [[ "$go_hash" == "unknown" && -f "/tmp/go${GO_VER}.linux-amd64.tar.gz" ]] && \
      go_hash="$(sha256sum "/tmp/go${GO_VER}.linux-amd64.tar.gz" | cut -d' ' -f1)"

    echo '      "sha256": "'${go_hash}'"'
    echo '    },'
    echo '    "netbird": {'
    echo '      "version": "'${NETBIRD_TAG}'",'
    echo '      "source": "https://github.com/netbirdio/netbird",'
    echo '      "type": "git_tag"'
    echo '    }'
    echo '  },'

    # -------------------------------------------------------------------------
    # Host tool versions
    # -------------------------------------------------------------------------
    echo '  "host_environment": {'
    echo '    "gcc": "'$(gcc --version 2>/dev/null | head -n1 || echo "unknown")'",'
    echo '    "make": "'$(make --version 2>/dev/null | head -n1 || echo "unknown")'",'
    echo '    "bash": "'${BASH_VERSION:-unknown}'",'
    echo '    "kernel": "'$(uname -r)'",'
    echo '    "hostname": "'$(hostname)'"'
    echo '  }'

    echo "}"
  } > "$pins_file"

  # Validate JSON if jq is available
  if command -v jq &>/dev/null; then
    if jq . "$pins_file" > "${pins_file}.tmp" 2>/dev/null; then
      mv "${pins_file}.tmp" "$pins_file"
      echo "Source pins validated: $pins_file"
    else
      echo "WARN: JSON validation failed for source-pins.json"
      rm -f "${pins_file}.tmp"
    fi
  fi

  # -------------------------------------------------------------------------
  # Create reproducibility manifest
  # -------------------------------------------------------------------------
  echo "Creating reproducibility manifest..."

  local manifest="${cfg_dir}/MANIFEST.txt"
  {
    echo "=========================================="
    echo "GA Build Configuration Archive"
    echo "=========================================="
    echo "Build ID:        ${GA_BUILD_TIMESTAMP}"
    echo "Build Date:      $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Defconfig:       ${DEFCONFIG}"
    echo ""
    echo "Contents:"
    echo "  buildroot.config     - Final Buildroot .config"
    echo "  kernel.config        - Final Linux kernel .config"
    echo "  ${DEFCONFIG}         - Original defconfig"
    echo "  kernel-fragments/    - Kernel config fragments"
    echo "  device-tree/         - DTB files and DTS sources"
    echo "  source-pins.json     - Git SHAs and tarball hashes"
    echo ""
    echo "File checksums:"
    find "$cfg_dir" -type f ! -name "MANIFEST.txt" -exec sha256sum {} \;
  } > "$manifest"

  # Also copy configs into target rootfs for runtime inspection
  mkdir -p "${OUT}/target/etc/ga-build"
  cp "$pins_file" "${OUT}/target/etc/ga-build/"
  cp "$manifest" "${OUT}/target/etc/ga-build/"

  # -------------------------------------------------------------------------
  # 7) Container image digest lockfile (pin by SHA256, not just tag)
  # -------------------------------------------------------------------------
  echo "[8/8] Creating container image digest lockfile..."

  local container_lock="${cfg_dir}/container-images.lock"
  local images_dir
  images_dir="$(ls -d ${OUT}/build/hassio-*/images 2>/dev/null | head -n 1 || true)"

  {
    echo "# Container Image Lockfile"
    echo "# Generated: $(date '+%Y-%m-%dT%H:%M:%S')"
    echo "# Build ID: ${GA_BUILD_TIMESTAMP}"
    echo "#"
    echo "# Format: <full-image-reference>  <sha256-digest>  <tar-file-sha256>"
    echo "# Use these digests to pull exact same images for reproducible builds"
    echo "#"

    if [[ -d "$images_dir" ]]; then
      for tarfile in "$images_dir"/*.tar; do
        [[ -f "$tarfile" ]] || continue

        local basename
        basename="$(basename "$tarfile" .tar)"

        # Parse: ghcr.io_home-assistant_armv7-hassio-audio_2025.08.0@sha256_425378ab...
        if [[ "$basename" =~ ^([^_]+)_(.+)_([^_]+)@sha256_([a-f0-9]+)$ ]]; then
          local registry="${BASH_REMATCH[1]}"
          local middle="${BASH_REMATCH[2]}"
          local tag="${BASH_REMATCH[3]}"
          local digest="${BASH_REMATCH[4]}"

          # Reconstruct image reference
          local image_ref="${registry}/${middle//_//}:${tag}"
          local tar_sha256
          tar_sha256="$(sha256sum "$tarfile" | cut -d' ' -f1)"

          echo "${image_ref}  sha256:${digest}  tar:${tar_sha256}"
        fi
      done
    else
      echo "# WARNING: No container images directory found"
    fi
  } > "$container_lock"

  echo "Container lockfile created: $container_lock"

  # Also create a JSON version for programmatic access
  local container_lock_json="${cfg_dir}/container-images.lock.json"
  {
    echo "{"
    echo '  "generated": "'$(date '+%Y-%m-%dT%H:%M:%S')'",'
    echo '  "build_id": "'${GA_BUILD_TIMESTAMP}'",'
    echo '  "images": ['

    local first=true
    if [[ -d "$images_dir" ]]; then
      for tarfile in "$images_dir"/*.tar; do
        [[ -f "$tarfile" ]] || continue

        local basename
        basename="$(basename "$tarfile" .tar)"

        if [[ "$basename" =~ ^([^_]+)_(.+)_([^_]+)@sha256_([a-f0-9]+)$ ]]; then
          local registry="${BASH_REMATCH[1]}"
          local middle="${BASH_REMATCH[2]}"
          local tag="${BASH_REMATCH[3]}"
          local digest="${BASH_REMATCH[4]}"

          local image_ref="${registry}/${middle//_//}:${tag}"
          local tar_sha256
          tar_sha256="$(sha256sum "$tarfile" | cut -d' ' -f1)"

          [[ "$first" == "true" ]] || echo ","
          first=false

          cat <<CONTAINEREOF
    {
      "image": "${image_ref}",
      "digest": "sha256:${digest}",
      "tar_sha256": "${tar_sha256}",
      "tar_file": "$(basename "$tarfile")"
    }
CONTAINEREOF
        fi
      done
    fi

    echo "  ]"
    echo "}"
  } > "$container_lock_json"

  # Validate JSON
  if command -v jq &>/dev/null; then
    if jq . "$container_lock_json" > "${container_lock_json}.tmp" 2>/dev/null; then
      mv "${container_lock_json}.tmp" "$container_lock_json"
    else
      rm -f "${container_lock_json}.tmp"
    fi
  fi

  echo "=== Build configuration archive complete: ${cfg_dir} ==="
  ls -la "$cfg_dir"
}

# -----------------------------------------------------------------------------
# Software Bill of Materials (SBOM) generation
# -----------------------------------------------------------------------------

# Generate SBOMs:
#   1) CycloneDX SBOM for Buildroot packages (standards-compliant, fast)
#   2) Container image inventory (not covered by Buildroot's tooling)
generate_sbom() {
  echo "=== Generating Software Bill of Materials ==="

  # --- 1) CycloneDX SBOM from Buildroot (packages only) ---
  local cyclonedx="${OUT}/images/sbom-cyclonedx.json"
  local generate_tool="${BUILDROOT_DIR}/utils/generate-cyclonedx"

  if [[ -x "$generate_tool" ]] || [[ -f "$generate_tool" ]]; then
    echo "Generating CycloneDX SBOM via Buildroot show-info..."
    local sbom_err="${OUT}/images/.sbom-err.log"
    local show_info_json="${OUT}/images/.show-info.json"

    # Diagnostic: verify .config exists (required for show-info to list packages)
    if [[ ! -f "${OUT}/.config" ]]; then
      echo "WARN: ${OUT}/.config not found, show-info will produce empty output"
    fi

    # Clear MAKEFLAGS to prevent stale jobserver file descriptors from the
    # previous parallel build from interfering with this standalone make call.
    # GNU Make inherits MAKEFLAGS (including --jobserver-auth=R,W) via the
    # environment; when the parent make has exited, those FDs are closed and
    # the child make can fail silently on Make 4.3 (Debian Bullseye).
    local saved_makeflags="${MAKEFLAGS:-}"
    unset MAKEFLAGS

    # Step 1: collect show-info JSON (separate from pipe so errors are visible)
    if make --no-print-directory -C "$BUILDROOT_DIR" O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" \
        show-info > "$show_info_json" 2>"$sbom_err"; then
      # Verify JSON is non-empty before feeding to generator
      if [[ ! -s "$show_info_json" ]]; then
        echo "WARN: make show-info exited 0 but produced empty output"
        echo "  .config exists: $(test -f "${OUT}/.config" && echo yes || echo NO)"
        echo "  BR2_HAVE_DOT_CONFIG: $(grep -c 'BR2_HAVE_DOT_CONFIG=y' "${OUT}/.config" 2>/dev/null || echo 'missing')"
        echo "  make version: $(make --version 2>/dev/null | head -1)"
        # Diagnostic: try show-targets (simpler, same PACKAGES variable)
        local target_count
        target_count="$(make --no-print-directory -C "$BUILDROOT_DIR" O="$OUT" \
            BR2_EXTERNAL="$BR2_EXTERNAL_PATH" show-targets 2>/dev/null | wc -w)"
        echo "  show-targets package count: ${target_count:-0}"
        cat "$sbom_err" 2>/dev/null | head -10
        rm -f "$show_info_json" "$sbom_err"
        export MAKEFLAGS="$saved_makeflags"
        return
      fi
      echo "  show-info JSON size: $(wc -c < "$show_info_json") bytes"
      # Step 2: feed JSON into the CycloneDX generator
      if python3 "$generate_tool" -i "$show_info_json" > "$cyclonedx" 2>>"$sbom_err"; then
        echo "CycloneDX SBOM generated: $cyclonedx"
        if command -v jq &>/dev/null; then
          jq . "$cyclonedx" > "${cyclonedx}.tmp" 2>/dev/null && mv "${cyclonedx}.tmp" "$cyclonedx"
        fi
      else
        echo "WARN: CycloneDX generator failed (see ${sbom_err}):"
        cat "$sbom_err" 2>/dev/null | head -20
        rm -f "$cyclonedx"
      fi
    else
      echo "WARN: make show-info failed (exit $?) (see ${sbom_err}):"
      cat "$sbom_err" 2>/dev/null | head -20
    fi
    rm -f "$show_info_json" "$sbom_err"
    export MAKEFLAGS="$saved_makeflags"
  else
    echo "WARN: generate-cyclonedx not found at $generate_tool, skipping CycloneDX SBOM"
  fi

  # --- 2) Container image inventory ---
  local containers_file="${OUT}/images/sbom-containers.json"
  local version_json
  version_json="$(ls ${OUT}/build/hassio-*/version.json 2>/dev/null | head -n 1 || true)"
  local images_dir
  images_dir="$(ls -d ${OUT}/build/hassio-*/images 2>/dev/null | head -n 1 || true)"

  echo "Generating container image inventory..."
  {
    echo "{"
    echo '  "generated": "'$(date '+%Y-%m-%dT%H:%M:%S')'",'
    echo '  "build_id": "'${GA_BUILD_TIMESTAMP}'",'
    echo '  "standalone": {'
    echo '    "netbird": { "version": "'${NETBIRD_TAG}'", "go": "'${GO_VER}'" }'
    echo '  },'
    echo '  "containers": ['

    local first=true

    if [[ -f "$version_json" ]] && command -v jq &>/dev/null; then
      # Parse from version.json (preferred — has all metadata)
      for comp in supervisor dns audio cli multicast observer; do
        local ver img
        ver="$(jq -r ".${comp} // \"unknown\"" "$version_json")"
        img="$(jq -r ".images.${comp} // \"unknown\"" "$version_json" | sed 's/{arch}/armv7/g')"
        [[ "$first" == "true" ]] || echo ","
        first=false
        echo "    { \"name\": \"${comp}\", \"image\": \"${img}\", \"version\": \"${ver}\" }"
      done
      # core uses {machine} not {arch}
      local core_ver core_img
      core_ver="$(jq -r '.core // "unknown"' "$version_json")"
      core_img="$(jq -r '.images.core // "unknown"' "$version_json" | sed 's/{machine}/tinker/g')"
      echo ","
      echo "    { \"name\": \"core\", \"image\": \"${core_img}\", \"version\": \"${core_ver}\" }"

    elif [[ -d "$images_dir" ]]; then
      # Fallback: parse from tar filenames
      for tarfile in "$images_dir"/*.tar; do
        [[ -f "$tarfile" ]] || continue
        local bn
        bn="$(basename "$tarfile" .tar)"
        if [[ "$bn" =~ ^([^_]+)_(.+)_([^_]+)@sha256_([a-f0-9]+)$ ]]; then
          [[ "$first" == "true" ]] || echo ","
          first=false
          local img="${BASH_REMATCH[1]}/${BASH_REMATCH[2]//_//}:${BASH_REMATCH[3]}"
          echo "    { \"image\": \"${img}\", \"digest\": \"sha256:${BASH_REMATCH[4]}\" }"
        fi
      done
    fi

    echo "  ]"
    echo "}"
  } > "$containers_file"

  # Validate
  if command -v jq &>/dev/null; then
    jq . "$containers_file" > "${containers_file}.tmp" 2>/dev/null && \
      mv "${containers_file}.tmp" "$containers_file"
  fi
  echo "Container inventory generated: $containers_file"

  # Install to target rootfs
  mkdir -p "${OUT}/target/etc"
  [[ -f "$cyclonedx" ]] && cp "$cyclonedx" "${OUT}/target/etc/ga-sbom-cyclonedx.json"
  cp "$containers_file" "${OUT}/target/etc/ga-sbom-containers.json"

  echo "=== SBOM generation complete ==="
}

# -----------------------------------------------------------------------------
# Image renaming and provisioning image creation
# -----------------------------------------------------------------------------

# Discover the original image basename produced by buildroot (e.g., haos_ihost-16.3)
# Returns the path without extension.
get_original_image_basename() {
  local img
  # Find the .img.xz or .img file in the images directory
  img="$(find "${OUT}/images" -maxdepth 1 -name 'haos_*.img.xz' -o -name 'haos_*.img' 2>/dev/null | head -n 1 || true)"
  if [[ -z "$img" ]]; then
    echo "ERROR: No haos_*.img or haos_*.img.xz found in ${OUT}/images" >&2
    return 1
  fi
  # Strip .img.xz or .img extension
  img="${img%.xz}"
  img="${img%.img}"
  echo "$img"
}

# Rename images with ga-build-id timestamp suffix and environment tag
# haos_ihost-16.3.img.xz -> gaos_ihost_CoreBox-16.3_dev_20260119123045.img.xz
# haos_ihost-16.3.raucb  -> gaos_ihost_CoreBox-16.3_prod_20260119123045.raucb
rename_images_with_build_id() {
  local orig_base new_base
  orig_base="$(get_original_image_basename)" || return 1

  # Convert haos_ prefix to gaos_ and append environment + timestamp
  local orig_name new_name
  local env_tag="${GA_ENV:-dev}"
  orig_name="$(basename "$orig_base")"
  new_name="${orig_name/haos_/gaos_}_${env_tag}_${GA_BUILD_TIMESTAMP}"
  new_base="$(dirname "$orig_base")/${new_name}"

  echo "Renaming images: ${orig_name} -> ${new_name}"

  # Rename .img.xz (compressed disk image)
  if [[ -f "${orig_base}.img.xz" ]]; then
    mv -v "${orig_base}.img.xz" "${new_base}.img.xz"
  elif [[ -f "${orig_base}.img" ]]; then
    # If not compressed yet, rename the .img
    mv -v "${orig_base}.img" "${new_base}.img"
  fi

  # Rename .raucb (RAUC bundle)
  if [[ -f "${orig_base}.raucb" ]]; then
    mv -v "${orig_base}.raucb" "${new_base}.raucb"
  fi

  # Export for use by provisioning image creation
  export GA_IMAGE_BASENAME="${new_base}"
  echo "GA_IMAGE_BASENAME=${GA_IMAGE_BASENAME}"
}

ensure_host_genimage() {
  if command -v genimage >/dev/null 2>&1; then
    echo "genimage found in PATH: $(command -v genimage)"
    return 0
  fi

  # If Buildroot already built it, just use it
  if [[ -x "${OUT}/host/bin/genimage" ]]; then
    export PATH="${OUT}/host/bin:${PATH}"
    echo "Using Buildroot host genimage: ${OUT}/host/bin/genimage"
    return 0
  fi

  echo "genimage not found; building Buildroot host-genimage..."
  make -C "$BUILDROOT_DIR" O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" host-genimage
  export PATH="${OUT}/host/bin:${PATH}"

  command -v genimage >/dev/null 2>&1 || {
    echo "ERROR: host-genimage build succeeded but genimage still not in PATH" >&2
    exit 1
  }
}


# Create a provisioning (factory) image that embeds the .img.xz inside /mnt/data/images/
# This requires:
#  1) Creating a larger data partition that can hold the embedded image
#  2) Copying the .img.xz into the data partition filesystem
#  3) Regenerating the disk image with the larger data partition
create_provisioning_image() {
  local img_xz="${GA_IMAGE_BASENAME}.img.xz"

  if [[ ! -f "$img_xz" ]]; then
    echo "ERROR: Cannot create provisioning image - ${img_xz} not found" >&2
    return 1
  fi

  echo "=== Creating provisioning image ==="

  # Calculate required data partition size
  local img_size_bytes img_size_mb data_size_mb
  img_size_bytes="$(stat -c%s "$img_xz")"
  img_size_mb=$(( (img_size_bytes / 1024 / 1024) + 1 ))  # Round up to MB

  # Add margin: original DATA_SIZE (1280M default) + embedded image size + 128M buffer
  local orig_data_size_mb=1280
  data_size_mb=$(( orig_data_size_mb + img_size_mb + 128 ))

  echo "Embedded image size: ${img_size_mb}M"
  echo "Provisioning data partition size: ${data_size_mb}M"

  # Create a temporary directory for the provisioning data partition content
  local prov_data_dir="${OUT}/build/provisioning-data"
  rm -rf "$prov_data_dir"
  mkdir -p "${prov_data_dir}/images"

  # Copy the compressed image into the data partition content
  local embedded_name
  embedded_name="$(basename "$img_xz")"
  cp -v "$img_xz" "${prov_data_dir}/images/${embedded_name}"

  # Create the provisioning data.ext4 image
  local prov_data_img="${OUT}/images/data-provisioning.ext4"
  echo "Creating provisioning data partition: ${prov_data_img} (${data_size_mb}M)"

  # Create ext4 filesystem with the embedded image
  rm -f "$prov_data_img"
  truncate -s "${data_size_mb}M" "$prov_data_img"
  mkfs.ext4 -q -L hassos-data -d "$prov_data_dir" "$prov_data_img"

  # Now we need to create a new disk image using the provisioning data partition
  # We'll use genimage with a modified DATA_IMAGE path
  local prov_img="${GA_IMAGE_BASENAME}_provisioning.img"
  echo "Creating provisioning disk image: ${prov_img}"

  # Save original data image path and set provisioning one
  local orig_data_image="${OUT}/images/data.ext4"

  # Backup original data.ext4 and replace with provisioning version
  if [[ -f "$orig_data_image" ]]; then
    mv "$orig_data_image" "${orig_data_image}.orig"
  fi
  mv "$prov_data_img" "$orig_data_image"

  # Recalculate disk size for provisioning image
  # DISK_SIZE needs to accommodate the larger data partition
  local orig_disk_size="${DISK_SIZE:-3800M}"
  local disk_size_num="${orig_disk_size%M}"
  local extra_mb=$(( data_size_mb - orig_data_size_mb ))
  local prov_disk_size_mb=$(( disk_size_num + extra_mb ))

  echo "Provisioning disk size: ${prov_disk_size_mb}M (original: ${orig_disk_size})"

  # Run genimage to create the provisioning disk image
  local genimage_tmp="${OUT}/build/genimage-prov.tmp"
  rm -rf "$genimage_tmp"

  local board_dir="${BR2EXT_IHOST}/board/sonoff/ihost"

  # Load board meta file for genimage variables
  local meta_file="${board_dir}/meta"
  if [[ -f "$meta_file" ]]; then
    echo "Loading board meta from: $meta_file"
    # shellcheck source=/dev/null
    . "$meta_file"
  else
    echo "WARN: Board meta file not found at $meta_file, using defaults"
    # iHost defaults
    PARTITION_TABLE_TYPE="gpt"
    BOOT_SPL="true"
    BOOTLOADER="uboot"
    KERNEL_FILE="zImage"
    BOOT_SIZE="16M"
    BOOT_SPL_SIZE="16M"
  fi

  # Export all variables required by genimage configs
  # Variables from meta file
  export PARTITION_TABLE_TYPE BOOTLOADER KERNEL_FILE BOOT_SIZE BOOT_SPL BOOT_SPL_SIZE

  # Derived variables
  export BOOT_SPL_TYPE
  BOOT_SPL_TYPE=$(test "$BOOT_SPL" == "true" && echo "spl" || echo "nospl")

  # Size variables for partitions (from hdd-image.sh defaults)
  export BOOTSTATE_SIZE="${BOOTSTATE_SIZE:-8M}"
  export SYSTEM_SIZE="${SYSTEM_SIZE:-300M}"
  export KERNEL_SIZE="${KERNEL_SIZE:-24M}"
  export OVERLAY_SIZE="${OVERLAY_SIZE:-96M}"

  # Provisioning-specific overrides
  export DATA_SIZE="${data_size_mb}M"
  export DISK_SIZE="${prov_disk_size_mb}M"
  export IMAGE_NAME="${GA_IMAGE_BASENAME}_provisioning"
  export GENIMAGE_TMPPATH="$genimage_tmp"

  # Image paths
  export SYSTEM_IMAGE="${OUT}/images/rootfs.erofs"
  export DATA_IMAGE="${OUT}/images/data.ext4"

  # Genimage also needs BINARIES_DIR for images-os.cfg
  export BINARIES_DIR="${OUT}/images"

  echo "Genimage variables:"
  echo "  PARTITION_TABLE_TYPE=$PARTITION_TABLE_TYPE"
  echo "  BOOT_SPL_TYPE=$BOOT_SPL_TYPE"
  echo "  DATA_SIZE=$DATA_SIZE"
  echo "  DISK_SIZE=$DISK_SIZE"
  echo "  IMAGE_NAME=$IMAGE_NAME"

  # Find the genimage config - check multiple possible locations
  local genimage_cfg=""
  for cfg_path in \
    "${BR2EXT_NETBIRD}/genimage/genimage.cfg" \
    "${OUT}/build/genimage.cfg" \
    "${BUILDROOT_DIR}/../buildroot-external/genimage/genimage.cfg" \
    "/build/buildroot-external/genimage/genimage.cfg"
  do
    if [[ -f "$cfg_path" ]]; then
      genimage_cfg="$cfg_path"
      break
    fi
  done

  if [[ -z "$genimage_cfg" ]]; then
    echo "ERROR: Cannot find genimage.cfg in any expected location" >&2
    echo "Searched: ${BR2EXT_NETBIRD}/genimage/, ${OUT}/build/, ${BUILDROOT_DIR}/../buildroot-external/genimage/" >&2
    # Restore original data.ext4 before failing
    rm -f "$orig_data_image"
    if [[ -f "${orig_data_image}.orig" ]]; then
      mv "${orig_data_image}.orig" "$orig_data_image"
    fi
    return 1
  fi

  local genimage_include_dir="$(dirname "$genimage_cfg")"
  echo "Using genimage config: $genimage_cfg"
  echo "Include path: ${board_dir}:${genimage_include_dir}"

  # Debug: verify the config file is actually accessible
  echo "Debug: checking genimage config accessibility..."
  ls -la "$genimage_cfg" || true
  head -5 "$genimage_cfg" || true

  # If the original config path fails, copy it to a local location
  local local_genimage_cfg="${OUT}/build/genimage-prov.cfg"
  if ! head -1 "$genimage_cfg" &>/dev/null; then
    echo "WARN: Cannot read $genimage_cfg directly, this may cause genimage to fail"
  fi

  # Copy config and all includes to a temporary location to ensure genimage can access them
  local local_genimage_dir="${OUT}/build/genimage-configs"
  rm -rf "$local_genimage_dir"
  mkdir -p "$local_genimage_dir"

  # Copy all genimage configs from the include directories (except main genimage.cfg)
  cp -v "${genimage_include_dir}"/*.cfg "$local_genimage_dir/" 2>/dev/null || true
  cp -v "${board_dir}"/*.cfg "$local_genimage_dir/" 2>/dev/null || true

  # Create a custom genimage config for provisioning that ONLY generates .img (no .raucb)
  # The original genimage.cfg includes the raucb which requires signing keys
  local_genimage_cfg="${local_genimage_dir}/genimage-provisioning.cfg"
  cat > "$local_genimage_cfg" <<'GENIMAGE_EOF'
include("images-os.cfg")

image "${IMAGE_NAME}.img" {
	size = "${DISK_SIZE:-2G}"

	include("hdimage-${PARTITION_TABLE_TYPE}.cfg")

	include("partition-spl-${BOOT_SPL_TYPE}.cfg")

	include("partitions-os-${PARTITION_TABLE_TYPE}.cfg")
}
GENIMAGE_EOF

  # Verify copied files
  echo "Copied genimage configs:"
  ls -la "$local_genimage_dir/"

  echo "Custom provisioning genimage config:"
  cat "$local_genimage_cfg"

  echo "Running genimage with provisioning config: $local_genimage_cfg"
  echo "Working directory for genimage: $local_genimage_dir"

  # Run genimage from the config directory to ensure relative includes work
  (
    cd "$local_genimage_dir"
    genimage \
      --rootpath "$(mktemp -d)" \
      --inputpath "${OUT}/images" \
      --outputpath "${OUT}/images" \
      --includepath "." \
      --config "genimage-provisioning.cfg"
  )

  # Compress the provisioning image
  if [[ -f "${prov_img}" ]]; then
    echo "Compressing provisioning image..."
    xz -3 -T0 "${prov_img}"
    echo "Created: ${prov_img}.xz"
  fi

  # Restore original data.ext4
  rm -f "$orig_data_image"
  if [[ -f "${orig_data_image}.orig" ]]; then
    mv "${orig_data_image}.orig" "$orig_data_image"
  fi

  # Cleanup
  rm -rf "$prov_data_dir" "$genimage_tmp"

  echo "=== Provisioning image created ==="
}

# -----------------------------------------------------------------------------
# License/legal-info archiving
# -----------------------------------------------------------------------------

archive_legal_info() {
  echo "=== Archiving Buildroot legal-info (licenses) ==="

  local legal_dir="${OUT}/legal-info"
  local archive_dir="${OUT}/images/legal-info"

  # Generate legal-info if not already present
  if [[ ! -d "$legal_dir" ]]; then
    echo "Generating Buildroot legal-info..."
    make -C "$BUILDROOT_DIR" O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" legal-info || {
      echo "WARN: legal-info generation failed, skipping"
      return 0
    }
  fi

  if [[ ! -d "$legal_dir" ]]; then
    echo "WARN: legal-info directory not found after generation"
    return 0
  fi

  # Create compressed archive of legal-info
  mkdir -p "$archive_dir"

  # Copy manifest files (small, useful for quick reference)
  for manifest in "$legal_dir"/*.csv "$legal_dir"/*.html "$legal_dir"/host-manifest.* "$legal_dir"/manifest.*; do
    [[ -f "$manifest" ]] && cp -v "$manifest" "$archive_dir/"
  done

  # Create compressed tarball of full legal-info (licenses + sources can be large)
  local legal_tarball="${archive_dir}/legal-info-full.tar.xz"
  echo "Creating legal-info archive: $legal_tarball"
  tar -C "$OUT" -cJf "$legal_tarball" legal-info/

  # Generate license summary
  local license_summary="${archive_dir}/LICENSE-SUMMARY.txt"
  {
    echo "=========================================="
    echo "License Summary for GA Build ${GA_BUILD_TIMESTAMP}"
    echo "=========================================="
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    if [[ -f "$legal_dir/manifest.csv" ]]; then
      echo "=== Package License Overview ==="
      echo ""
      # Extract unique licenses from manifest
      echo "Licenses used:"
      tail -n +2 "$legal_dir/manifest.csv" | cut -d',' -f5 | sort -u | grep -v '^$' | while read -r lic; do
        local count
        count="$(grep -c ",$lic," "$legal_dir/manifest.csv" 2>/dev/null || echo "0")"
        echo "  $lic: $count package(s)"
      done
      echo ""
      echo "Total packages: $(tail -n +2 "$legal_dir/manifest.csv" | wc -l)"
    fi

    if [[ -f "$legal_dir/host-manifest.csv" ]]; then
      echo ""
      echo "=== Host Tools License Overview ==="
      echo "Total host packages: $(tail -n +2 "$legal_dir/host-manifest.csv" | wc -l)"
    fi
  } > "$license_summary"

  echo "License summary created: $license_summary"

  # Also copy to target for runtime inspection
  mkdir -p "${OUT}/target/etc/ga-build"
  cp "$license_summary" "${OUT}/target/etc/ga-build/"

  echo "=== Legal-info archiving complete ==="
  ls -la "$archive_dir"
}

# -----------------------------------------------------------------------------
# Build logging
# -----------------------------------------------------------------------------

# Global build log file path
BUILD_LOG="${OUT}/images/build.log"

# Start build logging - call this at the beginning of build
start_build_log() {
  mkdir -p "$(dirname "$BUILD_LOG")"

  {
    echo "=========================================="
    echo "GA Build Log"
    echo "=========================================="
    echo "Build ID:     ${GA_BUILD_TIMESTAMP}"
    echo "Start time:   $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Mode:         ${MODE}"
    echo "Defconfig:    ${DEFCONFIG:-ga_ihost_full_defconfig}"
    echo "Host:         $(hostname)"
    echo "User:         $(whoami)"
    echo "PWD:          $(pwd)"
    echo ""
    echo "=== Environment ==="
    echo "BUILDROOT_DIR=$BUILDROOT_DIR"
    echo "BR2EXT_IHOST=$BR2EXT_IHOST"
    echo "BR2EXT_NETBIRD=$BR2EXT_NETBIRD"
    echo "OUT=$OUT"
    echo "NETBIRD_TAG=$NETBIRD_TAG"
    echo "GO_VER=$GO_VER"
    echo ""
    echo "=== System Info ==="
    echo "Kernel: $(uname -a)"
    echo "CPUs: $(nproc)"
    echo "Memory: $(free -h 2>/dev/null | grep Mem || echo 'unknown')"
    echo "Disk: $(df -h "$OUT" 2>/dev/null | tail -1 || echo 'unknown')"
    echo ""
    echo "=== Build Output ==="
  } > "$BUILD_LOG"

  echo "Build log started: $BUILD_LOG"
}

# Log a build step with timestamp
log_build_step() {
  local step="$1"
  local status="${2:-started}"

  {
    echo ""
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] === $step ($status) ==="
  } >> "$BUILD_LOG"
}

# Finalize build log
finalize_build_log() {
  local exit_code="${1:-0}"

  {
    echo ""
    echo "=========================================="
    echo "Build finished"
    echo "=========================================="
    echo "End time:   $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Exit code:  $exit_code"
    echo ""
    echo "=== Final disk usage ==="
    du -sh "$OUT"/* 2>/dev/null | head -20 || true
    echo ""
    echo "=== Output images ==="
    ls -la "${OUT}/images/"*.img.xz "${OUT}/images/"*.raucb 2>/dev/null || true
  } >> "$BUILD_LOG"

  # Create compressed copy
  if [[ -f "$BUILD_LOG" ]]; then
    xz -k -9 "$BUILD_LOG" 2>/dev/null || gzip -k -9 "$BUILD_LOG" 2>/dev/null || true
  fi

  echo "Build log finalized: $BUILD_LOG"
}

# Wrapper to run a command and log its output
run_logged() {
  local step_name="$1"
  shift

  log_build_step "$step_name" "started"

  # Run command, tee output to both console and log
  if "$@" 2>&1 | tee -a "$BUILD_LOG"; then
    log_build_step "$step_name" "completed"
    return 0
  else
    local rc=$?
    log_build_step "$step_name" "FAILED (exit code: $rc)"
    return $rc
  fi
}

# -----------------------------------------------------------------------------
# Build flow
# -----------------------------------------------------------------------------
cd "$BUILDROOT_DIR"
DEFCONFIG="ga_ihost_full_defconfig"

# Ensure dev-ca.pem exists for post-build script (link/copy from rel-ca.pem)
ensure_dev_ca_from_rel_ca

# 1) Configure
if [[ "$MODE" == "full" ]]; then
  rm -rf "$OUT"
  make O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" "$DEFCONFIG"

elif [[ "$MODE" == "partial" ]]; then
  make O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" "$DEFCONFIG"
  make O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" linux-dirclean hassio-dirclean

elif [[ "$MODE" == "kernel" ]]; then
  make O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" "$DEFCONFIG"
  make O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" linux-dirclean

elif [[ "$MODE" == "update" ]]; then
  make O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" "$DEFCONFIG"

else
  echo "Usage: $0 [full|partial|kernel|update|dev|prod] [dev|prod]"
  echo "       $0 dev   # shorthand for 'update dev'"
  echo "       $0 prod  # shorthand for 'update prod'"
  exit 1
fi

# Initialize build logging (after configure, so $OUT/images/ survives rm -rf in full mode)
start_build_log
log_build_step "Configure ($MODE mode)" "completed"

# 2) Prevent Buildroot from building netbird (Go requirement mismatch)
log_build_step "Disable Buildroot netbird"
disable_buildroot_netbird

# 3) Build full system normally
log_build_step "Buildroot main build"
make O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" -j"$(nproc)" 2>&1 | tee -a "$BUILD_LOG"

# 4) Build + inject NetBird 0.60.x using standalone Go 1.24.10
log_build_step "Install Go toolchain"
install_go_124_toolchain_for_standalone
log_build_step "Build NetBird standalone"
build_and_install_netbird_standalone

# 5) Inject build ID and regenerate final artifacts
log_build_step "Write build ID"
write_build_id_into_target
log_build_step "Verify outputs"
verify_outputs
log_build_step "Rebuild artifacts"
rebuild_artifacts

# 6) Rename images with ga-build-id timestamp suffix
log_build_step "Rename images"
rename_images_with_build_id

# --- Post-build artifacts (prod only for faster dev builds) ---
if [[ "$GA_ENV" == "prod" ]]; then
  # 7) Create provisioning image (factory image with embedded .img.xz)
  #    Disabled by default — enable with GA_PROVISIONING=true
  if [[ "${GA_PROVISIONING:-false}" == "true" ]]; then
    log_build_step "Ensure genimage"
    ensure_host_genimage
    log_build_step "Create provisioning image"
    create_provisioning_image
  else
    echo "Skipping provisioning image (set GA_PROVISIONING=true to enable)"
  fi

  # 8) Archive build configurations and pin all sources
  log_build_step "Archive build configs"
  archive_build_configs

  # 9) Archive legal-info (licenses)
  #    Disabled by default — enable with GA_LEGAL_INFO=true (slow, ~1.7GB output)
  if [[ "${GA_LEGAL_INFO:-false}" == "true" ]]; then
    log_build_step "Archive legal-info"
    archive_legal_info
  else
    echo "Skipping legal-info archive (set GA_LEGAL_INFO=true to enable)"
  fi

  # 10) Generate Software Bill of Materials (SBOM)
  log_build_step "Generate SBOM"
  generate_sbom 2>&1 | tee -a "$BUILD_LOG"
else
  echo "Skipping post-build artifacts for dev build (SBOMs, config archive, provisioning)"
  echo "  Use 'prod' environment for full artifact generation"
fi

# Finalize build log
finalize_build_log 0

cat <<'BANNER'

  ____  _   _ ___ _     ____    ____  _   _  ____ ____ _____ ____ ____
 | __ )| | | |_ _| |   |  _ \  / ___|| | | |/ ___/ ___| ____/ ___/ ___|
 |  _ \| | | || || |   | | | | \___ \| | | | |  | |   |  _| \___ \___ \
 | |_) | |_| || || |___| |_| |  ___) | |_| | |__| |___| |___ ___) |__) |
 |____/ \___/|___|_____|____/  |____/ \___/ \____\____|_____|____/____/

BANNER

# Build summary
kernel_ver="$(ls -d "${OUT}"/build/linux-* 2>/dev/null | head -n 1 | sed 's/.*linux-//' || echo "unknown")"
buildroot_ver="$(grep -E '^export BR2_VERSION :=' "${BUILDROOT_DIR}/Makefile" 2>/dev/null | sed 's/.*:= *//' || echo "unknown")"
nb_ver="$("${OUT}/target/usr/bin/netbird" version 2>/dev/null || echo "${NETBIRD_TAG}")"

echo "  Build ID:       ${GA_BUILD_TIMESTAMP}"
echo "  Environment:    ${GA_ENV}"
echo "  Mode:           ${MODE}"
echo "  Defconfig:      ${DEFCONFIG}"
echo "  Buildroot:      ${buildroot_ver}"
echo "  Kernel:         ${kernel_ver}"
echo "  NetBird:        ${nb_ver} (Go ${GO_VER})"
echo ""

echo "  Output images (this build):"
# Only show images from this build (matching current timestamp)
for f in "${OUT}/images/"*"${GA_BUILD_TIMESTAMP}"*.img.xz "${OUT}/images/"*"${GA_BUILD_TIMESTAMP}"*.raucb; do
  if [[ -f "$f" ]]; then
    sz="$(du -h "$f" | cut -f1)"
    echo "    $(basename "$f")  ${sz}"
  fi
done
echo ""

echo "  SBOMs:"
[[ -f "${OUT}/images/sbom-cyclonedx.json" ]] && echo "    sbom-cyclonedx.json   (Buildroot packages, CycloneDX 1.6)"
[[ -f "${OUT}/images/sbom-containers.json" ]] && echo "    sbom-containers.json  (Container images + standalone tools)"
echo ""

echo "  Configs:  ${OUT}/images/configs/"
if [[ "${GA_PROVISIONING:-false}" == "true" ]]; then
  echo "  Provisioning image: enabled"
else
  echo "  Provisioning image: skipped (GA_PROVISIONING=true to enable)"
fi
if [[ "${GA_LEGAL_INFO:-false}" == "true" ]]; then
  echo "  Legal info: ${OUT}/images/legal-info/"
else
  echo "  Legal info: skipped (GA_LEGAL_INFO=true to enable)"
fi
echo ""
echo "  Build log: ${BUILD_LOG}"
