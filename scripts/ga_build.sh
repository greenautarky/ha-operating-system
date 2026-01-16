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
#  4) Builds NetBird standalone with Go 1.24.10 and injects it into O/target
#  5) Writes build timestamp to /etc/ga-build-id in target rootfs
#  6) Ensures rel-ca.pem satisfies post-build expectation for dev-ca.pem (symlink/copy)
#  7) Re-finalizes target and rebuilds artifacts using 'all' (this tree has no 'images' target)
#
# Usage:
#   ./scripts/ga_build.sh [full|partial|kernel|update]
# -----------------------------------------------------------------------------

unset BR2_EXTERNAL

MODE="${1:-full}"   # full | partial | kernel | update

# ---- Paths inside container ----
BUILDROOT_DIR="${BUILDROOT_DIR:-/build/buildroot}"
BR2EXT_IHOST="${BR2EXT_IHOST:-/build/buildroot-ihost}"
BR2EXT_NETBIRD="${BR2EXT_NETBIRD:-/build/buildroot-external}"
BR2_EXTERNAL_PATH="${BR2EXT_IHOST}:${BR2EXT_NETBIRD}"

# Output dir (writable in container)
OUT="${OUT:-/build/ga_output}"
if [[ "$OUT" != /* ]]; then OUT="/build/${OUT}"; fi

# ---- NetBird standalone build settings ----
NETBIRD_TAG="${NETBIRD_TAG:-v0.61.0}"
GO_VER="${GO_VER:-1.24.10}"

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

write_build_id_into_target() {
  local ts
  ts="$(date -u '+%F %T')"  # UTC avoids ambiguity
  mkdir -p "${OUT}/target/etc"
  printf '%s\n' "$ts" > "${OUT}/target/etc/ga-build-id"
  echo "Wrote build id: $ts -> ${OUT}/target/etc/ga-build-id"
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

  echo "Downloading standalone Go ${GO_VER}..."
  wget -O "$tgz" "https://go.dev/dl/go${GO_VER}.linux-amd64.tar.gz"

  echo "Installing standalone Go ${GO_VER} into ${tool_dir}..."
  rm -rf /tmp/go
  tar -C /tmp -xzf "$tgz"

  rm -rf "$tool_dir"
  mkdir -p "${OUT}/host-tools"
  mv /tmp/go "$tool_dir"

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
  echo "Usage: $0 [full|partial|kernel|update]"
  exit 1
fi

# 2) Prevent Buildroot from building netbird (Go requirement mismatch)
disable_buildroot_netbird

# 3) Build full system normally
make O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" -j"$(nproc)"

# 4) Build + inject NetBird 0.60.x using standalone Go 1.24.10
install_go_124_toolchain_for_standalone
build_and_install_netbird_standalone

# 5) Inject build ID and regenerate final artifacts
write_build_id_into_target
verify_outputs
rebuild_artifacts
