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
#  8) Renames output images with ga-build-id timestamp suffix (haos_ -> bos_)
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
#   - bos_ihost-*.img.xz              Compressed disk image
#   - bos_ihost-*.raucb               RAUC update bundle
#   - bos_ihost-*_provisioning.img.xz Factory provisioning image
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
# Usage (order-independent):
#   ./scripts/ga_build.sh [full|partial|kernel|update] [dev|test|prod]
#   ./scripts/ga_build.sh dev full   # same as "full dev"
#   ./scripts/ga_build.sh dev        # shorthand for "full dev" (default mode=full)
#   ./scripts/ga_build.sh prod       # shorthand for "full prod"
#
# Modes (default: full):
#   full    - Clean build from scratch (rm -rf $OUT)
#   partial - Rebuild with linux-dirclean and hassio-dirclean
#   kernel  - Rebuild with linux-dirclean only
#   update  - Incremental build (reconfigure only)
#
# Environment (default: dev):
#   dev  - Development build: fast, skips post-build artifacts
#          (no SBOMs, no config archive, no provisioning image)
#   test - Alias for dev — use for canary / bench-test bakes (e.g. flashing K31
#          to gegencheck a change). Fast, no SBOM. Identical to dev.
#   prod - Production build: full artifacts for release (SBOMs, config archive,
#          provisioning if enabled). Use ONLY for actual fleet releases —
#          SBOMs are required for OSS-license compliance, so don't waste them
#          on throwaway canary bakes (use dev/test for those).
#
# Environment Variables (override defaults):
#   BUILDROOT_DIR    - Path to Buildroot source (default: /build/buildroot)
#   BR2EXT_IHOST     - Path to buildroot-ihost external tree (default: /build/buildroot-ihost)
#   BR2EXT_NETBIRD   - Path to buildroot-external tree (default: /build/buildroot-external)
#   OUT              - Output directory (default: /build/ga_output)
#   NETBIRD_TAG      - NetBird version tag (default: v0.71.4)
#   GA_BUILD_TIMESTAMP - Override build timestamp (default: auto-generated)
#   GA_ENV           - Environment stamp (default: from 2nd argument, or "dev")
#   GA_PROVISIONING  - Set to "true" to create provisioning image (default: false)
#   GA_LEGAL_INFO    - Set to "true" to generate legal-info archive (default: false)
#
# -----------------------------------------------------------------------------

# Buildroot's host-tar configure refuses to run as root without this
export FORCE_UNSAFE_CONFIGURE=1

unset BR2_EXTERNAL

# Optional runtime overrides passed to every make invocation as command-line
# arguments. Command-line make-vars beat ANY makefile assignment (=, :=, ?=),
# so this is the bullet-proof way to inject staged-rollout values without
# editing source. Currently used for HASSIO_VERSION_URL — pointing the
# hassio package's stable.json fetch at a non-main branch (e.g.
# release/v1.X-rebuild) for canary/iteration builds without exposing that
# value to the fleet via main. See ga-ihost-docs/RELEASE-STRATEGY.md.
#
# Why command-line and not env-var alone:
#   `?=` in hassio.mk would also respect environment, BUT Buildroot's
#   recursive make + sub-makes can strip or shadow env-vars depending on
#   MAKEFLAGS state. Command-line args are the only level that always wins.
declare -a MAKE_OVERRIDES=()
[ -n "${HASSIO_VERSION_URL:-}" ] && MAKE_OVERRIDES+=("HASSIO_VERSION_URL=${HASSIO_VERSION_URL}")

# Parse arguments: order-independent, e.g. "full dev" and "dev full" are equivalent.
#   Mode args:  full | partial | kernel | update  (default: full)
#   Env args:   dev | prod                        (default: dev)
#   Shorthands: "dev" alone => "update dev", "prod" alone => "update prod"
MODE=""
_CLI_ENV=""
for arg in "${@}"; do
  case "$arg" in
    full|partial|kernel|update)
      [[ -z "$MODE" ]] || { echo "ERROR: Duplicate mode argument: '$arg' (already have '$MODE')." >&2; exit 1; }
      MODE="$arg"
      ;;
    dev|test|prod)
      [[ -z "$_CLI_ENV" ]] || { echo "ERROR: Duplicate environment argument: '$arg' (already have '$_CLI_ENV')." >&2; exit 1; }
      _CLI_ENV="$arg"
      # 'test' = fast canary/bench build — pure alias for dev (no SBOM/archive/provisioning)
      [[ "$_CLI_ENV" == "test" ]] && _CLI_ENV="dev"
      ;;
    *)
      echo "ERROR: Unknown argument '$arg'. Usage: $0 [full|partial|kernel|update] [dev|test|prod]" >&2
      exit 1
      ;;
  esac
done
# CLI arg overrides GA_ENV env var
[[ -n "$_CLI_ENV" ]] && GA_ENV="$_CLI_ENV"
MODE="${MODE:-full}"
GA_ENV="${GA_ENV:-dev}"

# GA_ENV decides which signing key, which trust anchor, whether an SBOM is
# produced and how strict the CVE gate is. Every consumer compares it to the
# literal "prod", so ANY other spelling silently means dev — including
# "production", which reads like it worked and is the obvious thing to type.
# The CLI parser above already rejects a bad positional argument; this closes
# the same hole for `GA_ENV=production ./scripts/ga_build.sh full`.
case "$GA_ENV" in
  dev|prod) ;;
  *)
    echo "ERROR: GA_ENV='$GA_ENV' is not a valid environment." >&2
    echo "       Use exactly 'dev' or 'prod'. Anything else would silently" >&2
    echo "       build as dev with dev signing material." >&2
    exit 1
    ;;
esac
echo "Building with MODE=$MODE GA_ENV=$GA_ENV"

# ---- Paths inside container ----
BUILDROOT_DIR="${BUILDROOT_DIR:-/build/buildroot}"
BR2EXT_IHOST="${BR2EXT_IHOST:-/build/buildroot-ihost}"
BR2EXT_NETBIRD="${BR2EXT_NETBIRD:-/build/buildroot-external}"
BR2_EXTERNAL_PATH="${BR2EXT_IHOST}:${BR2EXT_NETBIRD}"

# Output dir (writable in container)
OUT="${OUT:-/build/ga_output}"
if [[ "$OUT" != /* ]]; then OUT="/build/${OUT}"; fi

# ---- NetBird version (built via Buildroot golang-package) ----
NETBIRD_TAG="${NETBIRD_TAG:-v0.71.4}"

# ---- CA files expected by post-build script ----
OTA_DIR="${OTA_DIR:-${BR2EXT_NETBIRD}/ota}"
REL_CA_PEM="${REL_CA_PEM:-${OTA_DIR}/rel-ca.pem}"
DEV_CA_PEM="${DEV_CA_PEM:-${OTA_DIR}/dev-ca.pem}"

echo "Using OUT=$OUT"
echo "Using BUILDROOT_DIR=$BUILDROOT_DIR"
echo "Using BR2EXT_DIR=$BR2EXT_NETBIRD"
echo "Using BR2_EXTERNAL=$BR2_EXTERNAL_PATH"
echo "Using NETBIRD_TAG=$NETBIRD_TAG"
echo "Using OTA_DIR=$OTA_DIR"
echo "Using REL_CA_PEM=$REL_CA_PEM"
echo "Using DEV_CA_PEM=$DEV_CA_PEM"

# Sanity: if scripts/sync-components.sh exists, the host (= the LXC / VM
# that runs the docker build invocation) must have run it BEFORE entering
# the build container. We don't run it from here — the build container's
# minimal hassos:local image doesn't carry oras/yq, and adding them just
# for this would bloat the image. The wrapper that invokes ga_build.sh
# is expected to run sync first; we just verify the synced files are
# present.
if [ -f "${REPO_ROOT:-$(pwd)}/version.yaml" ]; then
  # components: section — FAIL-FAST if a pinned Tier-2 component is missing
  # from the overlay, or version-mismatched. Without this a forgotten
  # `sync-components.sh` after a pin change ships an image WITHOUT the
  # component yet still exits 0 — the exact silent no-op that hid
  # greenautarky_telemetry from BOSv1.2.21-rc15 (2026-07-07). Mirrors the
  # rootfs_overlays check below. See memory feedback_ga_build_sync_first.
  in_components_block=0
  while IFS= read -r line; do
    case "$line" in
      "components:"*) in_components_block=1; continue;;
      [a-z]*":"*)     in_components_block=0;;
    esac
    [ "$in_components_block" -eq 1 ] || continue
    case "$line" in
      "  "[a-z]*":"*)
        comp=$(echo "$line" | awk '{print $1}' | tr -d ':')
        pinned=$(echo "$line" | awk '{print $2}' | tr -d '"' | sed 's/[#].*//' | tr -d '[:space:]')
        { [ -z "$pinned" ] || [ "$pinned" = "null" ]; } && continue
        domain="${comp//-/_}"
        dest="${REPO_ROOT:-$(pwd)}/buildroot-external/rootfs-overlay/usr/share/ga/custom_components/${domain}"
        if [ ! -f "${dest}/manifest.json" ]; then
          echo "FAIL: component '${comp}' pinned to ${pinned} but ${dest} is missing — run scripts/sync-components.sh first" >&2
          PREFLIGHT_FAIL_COMPONENT=1
        else
          on_disk=$(grep -oE '"version":[[:space:]]*"[^"]*"' "${dest}/manifest.json" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
          if [ "$on_disk" != "$pinned" ]; then
            echo "FAIL: component '${comp}' manifest says ${on_disk} but version.yaml pins ${pinned} — run scripts/sync-components.sh" >&2
            PREFLIGHT_FAIL_COMPONENT=1
          else
            echo "Component check: ${comp}@${pinned} ✓"
          fi
        fi
        ;;
    esac
  done < "${REPO_ROOT:-$(pwd)}/version.yaml"
  if [ "${PREFLIGHT_FAIL_COMPONENT:-0}" -eq 1 ]; then
    echo "" >&2
    echo "ABORT: components: out of sync (see FAIL lines above). Fix:" >&2
    echo "  (host)  cd ${REPO_ROOT:-$(pwd)} && ./scripts/sync-components.sh" >&2
    echo "  then re-run ga_build.sh inside the container." >&2
    exit 1
  fi

  # rootfs_overlays staleness check — fail fast if the on-disk synced
  # version doesn't match version.yaml. Without this, a forgotten
  # `sync-components.sh` ships an image with stale Tier-2 service files
  # but the build still exits 0 (see memory/feedback_ga_build_sync_first).
  marker_dir="${REPO_ROOT:-$(pwd)}/ga_output/.sync-markers"
  in_overlay_block=0
  while IFS= read -r line; do
    case "$line" in
      "rootfs_overlays:"*) in_overlay_block=1; continue;;
      [a-z]*":"*) in_overlay_block=0;;
    esac
    [ "$in_overlay_block" -eq 1 ] || continue
    case "$line" in
      "  "[a-z]*":"*)
        pkg=$(echo "$line" | awk '{print $1}' | tr -d ':')
        pinned=$(echo "$line" | awk '{print $2}' | tr -d '"' | sed 's/[#].*//' | tr -d '[:space:]')
        [ -z "$pinned" ] || [ "$pinned" = "null" ] && continue
        marker="${marker_dir}/${pkg}.synced-version"
        if [ ! -f "$marker" ]; then
          echo "FAIL: rootfs_overlay '${pkg}' pinned to ${pinned} but no sync marker — run scripts/sync-components.sh first" >&2
          PREFLIGHT_FAIL_OVERLAY=1
        else
          on_disk=$(cat "$marker")
          if [ "$on_disk" != "$pinned" ]; then
            echo "FAIL: rootfs_overlay '${pkg}' marker says ${on_disk} but version.yaml pins ${pinned} — run scripts/sync-components.sh" >&2
            PREFLIGHT_FAIL_OVERLAY=1
          else
            echo "Overlay check: ${pkg}@${pinned} ✓"
          fi
        fi
        ;;
    esac
  done < "${REPO_ROOT:-$(pwd)}/version.yaml"
  if [ "${PREFLIGHT_FAIL_OVERLAY:-0}" -eq 1 ]; then
    echo "" >&2
    echo "ABORT: rootfs_overlays out of sync. Fix:" >&2
    echo "  (host)  cd ${REPO_ROOT:-$(pwd)} && ./scripts/sync-components.sh" >&2
    echo "  then re-run ga_build.sh inside the container." >&2
    exit 1
  fi
fi

# ---- Sanity checks (fail fast) ----
echo "=== Pre-build validation ==="
PREFLIGHT_FAIL=0

[[ -d "$BUILDROOT_DIR" ]] || { echo "FAIL: BUILDROOT_DIR not found: $BUILDROOT_DIR" >&2; PREFLIGHT_FAIL=1; }
[[ -d "$BR2EXT_IHOST"  ]] || { echo "FAIL: BR2EXT_IHOST not found: $BR2EXT_IHOST" >&2; PREFLIGHT_FAIL=1; }
[[ -d "$BR2EXT_NETBIRD" ]] || { echo "FAIL: BR2EXT_NETBIRD not found: $BR2EXT_NETBIRD" >&2; PREFLIGHT_FAIL=1; }
[[ -f "$BR2EXT_IHOST/configs/ga_ihost_full_defconfig" ]] || {
  echo "FAIL: Defconfig not found: $BR2EXT_IHOST/configs/ga_ihost_full_defconfig" >&2; PREFLIGHT_FAIL=1;
}
[[ -f "${BUILDROOT_DIR}/utils/config" ]] || {
  echo "FAIL: Buildroot utils/config not found: ${BUILDROOT_DIR}/utils/config" >&2; PREFLIGHT_FAIL=1;
}

# Signing material for RAUC bundles — which pair depends on the build mode.
#
# A dev build must NOT reach for the production key. Before 2026-07-30 it did:
# rauc.sh used /build/key.pem unconditionally and ota/dev-ca.pem was a symlink
# to ota/rel-ca.pem, so a dev build produced a bundle every production device
# would install. The preflight below now asks for the pair that will actually
# be used, so a missing dev key fails here rather than silently falling through
# to the production one.
if [[ "$GA_ENV" == "prod" ]]; then
  _sign_cert="cert.pem"; _sign_key="key.pem"
else
  _sign_cert="dev-cert.pem"; _sign_key="dev-key.pem"
fi
[[ -f "/build/${_sign_cert}" ]] || [[ -f "${_sign_cert}" ]] || {
  echo "FAIL: RAUC signing cert (${_sign_cert}) not found for GA_ENV=${GA_ENV}" >&2; PREFLIGHT_FAIL=1;
}
[[ -f "/build/${_sign_key}" ]] || [[ -f "${_sign_key}" ]] || {
  echo "FAIL: RAUC signing key (${_sign_key}) not found for GA_ENV=${GA_ENV}" >&2; PREFLIGHT_FAIL=1;
}

# Secrets required for build
[[ -f "/build/secrets/wifi-install.psk" ]] || [[ -f "secrets/wifi-install.psk" ]] || {
  echo "WARN: secrets/wifi-install.psk not found — WiFi fallback will not work" >&2;
}
[[ -f "/build/secrets/openstick-wifi.key" ]] || [[ -f "secrets/openstick-wifi.key" ]] || {
  echo "WARN: secrets/openstick-wifi.key not found — OpenStick WiFi will not work" >&2;
}
# NetBird auto-register on first boot needs a reusable setup key from the
# NetBird admin panel. If absent, the OS builds fine but freshly-flashed
# devices stay in `Daemon status: NeedsLogin` and don't auto-tunnel —
# operator must register them via `netbird up` or ga-flasher-py stage 40.
[[ -f "/build/secrets/netbird-setup-key.txt" ]] || [[ -f "secrets/netbird-setup-key.txt" ]] || {
  echo "WARN: secrets/netbird-setup-key.txt not found — fresh-flash devices will NOT auto-register with NetBird" >&2;
}

# Version suffix set (not empty for release builds)
VERSION_SUFFIX_CHECK=$(grep 'VERSION_SUFFIX=' "$BR2EXT_NETBIRD/meta" 2>/dev/null | cut -d'"' -f2)
if [[ "$GA_ENV" == "prod" ]] && [[ -z "$VERSION_SUFFIX_CHECK" ]]; then
  echo "WARN: VERSION_SUFFIX is empty in meta — prod build will use base version only" >&2
fi

# NetBird version consistency: NETBIRD_TAG (ga_build.sh) must match netbird.mk
# Read the declared upstream tag, NOT NETBIRD_VERSION: since Vuln-11 the
# latter is a bare commit SHA, and the old `sed 's|.*refs/tags/v||'` silently
# matched nothing, leaving the whole line as the "version" — every bake then
# failed this pre-flight (first seen on the rc36 train, 2026-07-28).
NB_MK_VERSION=$(grep '^NETBIRD_UPSTREAM_TAG' "$BR2EXT_NETBIRD/package/netbird/netbird.mk" 2>/dev/null \
  | sed 's/.*=[[:space:]]*v\?//' | tr -d '[:space:]')
NB_TAG_VERSION="${NETBIRD_TAG#v}"
if [[ -n "$NB_MK_VERSION" ]] && [[ "$NB_MK_VERSION" != "$NB_TAG_VERSION" ]]; then
  echo "FAIL: NetBird version mismatch — NETBIRD_TAG=$NB_TAG_VERSION but netbird.mk=$NB_MK_VERSION" >&2
  echo "  Update NETBIRD_TAG in ga_build.sh or NETBIRD_VERSION in netbird.mk" >&2
  PREFLIGHT_FAIL=1
fi

if [[ $PREFLIGHT_FAIL -ne 0 ]]; then
  echo "FATAL: Pre-build validation failed — fix errors above before building" >&2
  exit 1
fi
echo "Pre-build validation passed."
echo ""

# Refuse to build without the trust anchor this environment is supposed to use,
# and refuse to build if the two anchors are the same file.
#
# This replaces ensure_dev_ca_from_rel_ca(), which created dev-ca.pem as a
# SYMLINK to rel-ca.pem whenever it was missing. That is exactly the defect the
# 2026-07-30 clean cut removed elsewhere: it made a dev image ship the
# PRODUCTION root CA while every log line said "dev". Both *.pem files are
# gitignored, so a fresh checkout on a new builder has neither — and the old
# function turned that ordinary state into a silent trust merge.
#
# Auto-creating signing trust material is never the right recovery. The keys
# live in /home/builder/secrets on the build host; if one is not there, the
# operator has to say which key this image should be installable with.
require_base_ca() {
  local _want _other
  if [[ "$GA_ENV" == "prod" ]]; then
    _want="$REL_CA_PEM"; _other="$DEV_CA_PEM"
  else
    _want="$DEV_CA_PEM"; _other="$REL_CA_PEM"
  fi

  if [[ ! -f "$_want" ]]; then
    echo "ERROR: GA_ENV=$GA_ENV needs $_want and it is not there." >&2
    echo "       Place the correct root CA (it is gitignored on purpose)." >&2
    echo "       Do NOT substitute the other environment's CA — that is how a" >&2
    echo "       dev image ends up installable with the production key." >&2
    exit 1
  fi

  # A symlink, a hardlink or a byte-identical copy all collapse the dev/prod
  # trust separation while looking like two distinct files in `ls`.
  if [[ -f "$_other" ]] && [[ "$(readlink -f "$_want")" == "$(readlink -f "$_other")" ]]; then
    echo "ERROR: $DEV_CA_PEM and $REL_CA_PEM resolve to the SAME file." >&2
    echo "       dev and prod would share one trust anchor. Refusing." >&2
    exit 1
  fi
  if [[ -f "$_other" ]] && cmp -s "$_want" "$_other"; then
    echo "ERROR: $DEV_CA_PEM and $REL_CA_PEM are byte-identical." >&2
    echo "       dev and prod would share one trust anchor. Refusing." >&2
    exit 1
  fi

  echo "Base CA for GA_ENV=$GA_ENV: $_want"
}

# Global build timestamp (compact format for filenames, set once at script start)
GA_BUILD_TIMESTAMP="${GA_BUILD_TIMESTAMP:-$(date '+%Y%m%d%H%M%S')}"

# GA-side release identifier (e.g. "BOSv1.2.3"). Lands in /etc/ga-release
# and /etc/os-release at post-build time so devices have a clean operator-
# facing version distinct from the HAOS-internal OS_VERSION (16.3.1.x).
#
# Resolution order (first non-empty wins):
#   1. The GA_RELEASE env var, if explicitly set (CI overrides etc.).
#   2. The `gaos_release:` key in version.yaml at the repo root.
#   3. Empty — skips the /etc/ga-release write entirely.
#
# The version.yaml fallback exists because `docker run -e GA_RELEASE=…`
# is silently stripped by `sudo -H` in hassos:local's entrypoint. The
# env-var-only path lost the value (BOSv1.2.0 build #15 shipped without
# the stamp); reading from version.yaml inside the container removes the
# env-propagation fragility. Tracked in fleet_auto_update_audit_2026_06_01
# follow-up.
GA_RELEASE_SOURCE=""
GA_RELEASE_FROM_YAML="$(sed -nE 's/^gaos_release:[[:space:]]*"?([^"#[:space:]]+)"?.*$/\1/p' \
                       "${SCRIPT_DIR}/../version.yaml" 2>/dev/null | head -1)"
if [[ -n "${GA_RELEASE:-}" ]]; then
  GA_RELEASE_SOURCE="env"
  # Mismatch detection: if BOTH env and version.yaml are set but differ,
  # the operator likely forgot to bump version.yaml. We pick env (= explicit
  # operator intent) but warn loudly so a stale yaml doesn't go unnoticed.
  if [[ -n "${GA_RELEASE_FROM_YAML}" && "${GA_RELEASE}" != "${GA_RELEASE_FROM_YAML}" ]]; then
    echo ""
    echo "===================================================="
    echo "  WARN: GA_RELEASE env ($GA_RELEASE) differs from"
    echo "        version.yaml's gaos_release ($GA_RELEASE_FROM_YAML)."
    echo ""
    echo "        Using env value. Bump version.yaml to match"
    echo "        if this is a real release (= avoid drift on"
    echo "        future builds that don't pass env)."
    echo "===================================================="
    echo ""
  fi
else
  GA_RELEASE="$GA_RELEASE_FROM_YAML"
  GA_RELEASE_SOURCE="version.yaml"
fi

# Fail-fast: empty GA_RELEASE means /etc/ga-release will be silently absent
# on the produced image — which then poisons the release-aware OTA cascade.
# Bake-time abort > runtime mystery.
if [[ -z "${GA_RELEASE}" ]]; then
  echo ""
  echo "===================================================="
  echo "  ERROR: GA_RELEASE could not be resolved."
  echo ""
  echo "    - env var GA_RELEASE: unset (or stripped by sudo -H"
  echo "      in hassos:local entrypoint — known limitation)"
  echo "    - version.yaml gaos_release: empty or missing"
  echo ""
  echo "    Fix: bump version.yaml's gaos_release: line to the"
  echo "    target release label (e.g. BOSv1.2.21-rc2), commit,"
  echo "    then re-run the build. See scripts/release.sh."
  echo "===================================================="
  exit 1
fi

# Loud resolution banner — operator MUST see what's about to land in
# /etc/ga-release before waiting 50 min for the build to finish.
echo ""
echo "===================================================="
echo "  GA_RELEASE resolution:"
echo "    value:  $GA_RELEASE"
echo "    source: $GA_RELEASE_SOURCE"
echo "===================================================="
echo ""

export GA_BUILD_TIMESTAMP GA_ENV GA_RELEASE

assert_ga_release_stamped() {
  # Post-bake guard: confirm /etc/ga-release in the produced rootfs matches
  # the resolved GA_RELEASE. Catches:
  #   - silent env-var stripping (= would have caught the BOSv1.2.21-rc2
  #     bake1 incident where env passed `BOSv1.2.21-rc2` but version.yaml
  #     still said `BOSv1.2.20-rc1` → image went out with the older label
  #     stamped, requiring a full rebake)
  #   - any future codepath that writes /etc/ga-release from a different
  #     variable than $GA_RELEASE without updating both spots
  # Runs after rebuild_artifacts so the build is "done" and we have the
  # final rootfs in target/. If this fails we abort before producing the
  # provisioning image / SBOM / archives (= those are mid-stream cost only).
  local stamped
  stamped="$(cat "${OUT}/target/etc/ga-release" 2>/dev/null || true)"
  if [[ -z "$stamped" ]]; then
    echo ""
    echo "===================================================="
    echo "  ERROR: post-bake assertion failed."
    echo "    /etc/ga-release is empty/missing in built rootfs."
    echo "    Expected: ${GA_RELEASE:-<unset>}"
    echo "===================================================="
    exit 1
  fi
  if [[ "$stamped" != "$GA_RELEASE" ]]; then
    echo ""
    echo "===================================================="
    echo "  ERROR: post-bake assertion failed."
    echo "    /etc/ga-release in built rootfs differs from resolved GA_RELEASE."
    echo "    In rootfs:  '$stamped'"
    echo "    Resolved:   '$GA_RELEASE'"
    echo ""
    echo "    Stop NOW — do not ship this image. The on-device"
    echo "    release-aware OTA cascade compares /etc/ga-release"
    echo "    to target_ga_release; a mismatch breaks the no-op"
    echo "    detection on subsequent updates."
    echo "===================================================="
    exit 1
  fi
  echo ""
  echo "  ✓ Post-bake assertion: /etc/ga-release = '$stamped' (matches resolved GA_RELEASE)"
  echo ""
}

write_build_id_into_target() {
  local ts_human
  ts_human="$(date '+%F %T')"  # Human-readable local time for /etc/ga-build-id
  mkdir -p "${OUT}/target/etc"
  printf '%s\n' "$ts_human" > "${OUT}/target/etc/ga-build-id"
  echo "Wrote build id: $ts_human -> ${OUT}/target/etc/ga-build-id"

  # Stamp GA-side release identifier (e.g. "BOSv1.2.0") into /etc/ga-release
  # AND append GA_RELEASE="…" to /etc/os-release. Done here (post-buildroot,
  # in the parent ga_build.sh shell) rather than in
  # buildroot-external/scripts/post-build.sh because Buildroot's
  # BR2_ROOTFS_POST_BUILD_SCRIPT invocation drops the GA_RELEASE env var
  # while preserving GA_BUILD_TIMESTAMP (observed BOSv1.2.0 build #8 — the
  # post-build.sh code IS the same shape; only GA_RELEASE goes missing).
  # write_build_id_into_target() runs at line ~1855 with the full env, so
  # /etc/ga-release reliably lands here.
  if [[ -n "${GA_RELEASE:-}" ]]; then
    printf '%s\n' "$GA_RELEASE" > "${OUT}/target/etc/ga-release"
    chmod 0644 "${OUT}/target/etc/ga-release"
    echo "Wrote GA release: $GA_RELEASE -> ${OUT}/target/etc/ga-release"
    local os_release="${OUT}/target/etc/os-release"
    local usr_os_release="${OUT}/target/usr/lib/os-release"
    for f in "$os_release" "$usr_os_release"; do
      if [[ -f "$f" ]]; then
        sed -i '/^GA_RELEASE=/d' "$f"
        printf 'GA_RELEASE="%s"\n' "$GA_RELEASE" >> "$f"
      fi
    done
    echo "Appended GA_RELEASE=\"$GA_RELEASE\" to /etc/os-release + /usr/lib/os-release"
  else
    echo "GA_RELEASE not set — skipping /etc/ga-release write (set GA_RELEASE env to enable)"
  fi

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

}

# Stamp GA build info into /etc/os-release (DEFINED but NEVER CALLED — kept
# for reference; the actual stamping happens in
# buildroot-external/scripts/post-build.sh via BR2_ROOTFS_POST_BUILD_SCRIPT,
# which DOES see the exported GA_BUILD_TIMESTAMP / GA_ENV / GA_RELEASE env vars).
stamp_os_release() {
  local os_release="${OUT}/target/etc/os-release"
  local ts_human
  ts_human="$(date '+%F %T')"
  local env_val="${GA_ENV:-dev}"

  if [[ -f "$os_release" ]]; then
    # Remove any previous GA entries to avoid duplicates on rebuilds
    sed -i '/^GA_BUILD_ID=/d; /^GA_BUILD_TIMESTAMP=/d; /^GA_ENV=/d' "$os_release"
    # Append new build info
    printf 'GA_BUILD_ID="%s (%s)"\n' "$ts_human" "$env_val" >> "$os_release"
    printf 'GA_BUILD_TIMESTAMP="%s"\n' "$GA_BUILD_TIMESTAMP" >> "$os_release"
    printf 'GA_ENV="%s"\n' "$env_val" >> "$os_release"
    echo "Stamped GA build info into: $os_release"
  else
    echo "WARN: $os_release not found, skipping os-release stamp"
  fi
}



# -----------------------------------------------------------------------------
# Frontend version resolution — reads Docker image labels from the core tar
# -----------------------------------------------------------------------------

# Reads org.greenautarky.frontend-* labels from the HA Core image tarball that
# the hassio Buildroot package downloads.  Call this after the main build.
# Sets (and exports) GA_FRONTEND_PYVERSION, GA_FRONTEND_SHA, GA_FRONTEND_VERSION.
resolve_frontend_version() {
  GA_FRONTEND_PYVERSION="unknown"
  GA_FRONTEND_SHA="unknown"
  GA_FRONTEND_VERSION="unknown"

  local images_dir
  images_dir="$(ls -d "${OUT}/build/hassio-"*/images 2>/dev/null | head -n 1 || true)"
  if [[ -z "$images_dir" ]]; then
    echo "  [fe-version] hassio images dir not found — skipping"
    return
  fi

  # Core image tar contains "homeassistant" and ends in .tar
  local core_tar
  core_tar="$(find "$images_dir" -maxdepth 1 -name "*homeassistant*.tar" 2>/dev/null | head -n 1 || true)"
  if [[ -z "$core_tar" ]]; then
    echo "  [fe-version] core image tar not found in $images_dir — skipping"
    return
  fi

  echo "  [fe-version] reading labels from: $(basename "$core_tar")"

  if ! command -v jq &>/dev/null; then
    echo "  [fe-version] jq not available — skipping"
    return
  fi

  # OCI image layout: manifest.json → config blob path → config.Labels
  local config_path
  config_path=$(tar -xOf "$core_tar" manifest.json 2>/dev/null \
    | jq -r '.[0].Config // empty' || true)
  if [[ -z "$config_path" ]]; then
    echo "  [fe-version] could not parse manifest.json from image tar — skipping"
    return
  fi

  local labels
  labels=$(tar -xOf "$core_tar" "$config_path" 2>/dev/null \
    | jq '.config.Labels // {}' || true)
  if [[ -z "$labels" || "$labels" == "null" ]]; then
    echo "  [fe-version] no labels in image config — skipping"
    return
  fi

  GA_FRONTEND_PYVERSION=$(echo "$labels" | jq -r '."org.greenautarky.frontend-pyversion" // "unknown"')
  GA_FRONTEND_SHA=$(echo "$labels"       | jq -r '."org.greenautarky.frontend-sha"       // "unknown"')
  GA_FRONTEND_VERSION=$(echo "$labels"   | jq -r '."org.greenautarky.frontend-version"   // "unknown"')

  echo "  [fe-version] pyversion: ${GA_FRONTEND_PYVERSION}"
  echo "  [fe-version] version:   ${GA_FRONTEND_VERSION}"
  echo "  [fe-version] sha:       ${GA_FRONTEND_SHA}"

  export GA_FRONTEND_PYVERSION GA_FRONTEND_SHA GA_FRONTEND_VERSION
}

# Write /etc/ga-frontend-version into the target rootfs.
# Readable at runtime via: cat /etc/ga-frontend-version
stamp_frontend_version_into_target() {
  if [[ "${GA_FRONTEND_PYVERSION:-unknown}" == "unknown" ]]; then
    echo "WARN: frontend version unknown — /etc/ga-frontend-version not written"
    return
  fi
  mkdir -p "${OUT}/target/etc"
  cat > "${OUT}/target/etc/ga-frontend-version" <<FEVEOF
# HA Core frontend version — written at OS build time
# Source: org.greenautarky.* labels in the core Docker image
GA_FRONTEND_PYVERSION=${GA_FRONTEND_PYVERSION}
GA_FRONTEND_VERSION=${GA_FRONTEND_VERSION}
GA_FRONTEND_SHA=${GA_FRONTEND_SHA}
FEVEOF
  echo "Stamped frontend version: ${GA_FRONTEND_PYVERSION} -> ${OUT}/target/etc/ga-frontend-version"
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

# Post-build integrity checks — runs after successful build, fails the build if critical issues found
verify_build_integrity() {
  echo ""
  echo "=== Post-build integrity checks ==="
  local pass=0 fail=0 warn=0

  _check_pass() { echo "  PASS  $1"; pass=$((pass+1)); }
  _check_fail() { echo "  FAIL  $1"; fail=$((fail+1)); }
  _check_warn() { echo "  WARN  $1"; warn=$((warn+1)); }

  # --- 1) Output images exist ---
  local img_xz
  img_xz="$(ls "${OUT}/images/"*".img.xz" 2>/dev/null | head -1)"
  if [[ -n "$img_xz" ]]; then
    local sz_mb
    sz_mb="$(du -m "$img_xz" | cut -f1)"
    _check_pass "Disk image exists (${sz_mb}MB)"
    # Sanity: image should be between 200MB and 2GB
    if (( sz_mb < 200 || sz_mb > 2048 )); then
      _check_warn "Image size ${sz_mb}MB outside expected range (200-2048MB)"
    fi
  else
    _check_fail "No .img.xz found in ${OUT}/images/"
  fi

  local raucb
  raucb="$(ls "${OUT}/images/"*".raucb" 2>/dev/null | head -1)"
  [[ -n "$raucb" ]] && _check_pass "RAUC bundle exists" || _check_fail "No .raucb found"

  # --- 2) NetBird binary ---
  # Cross-built ARM binary cannot be executed on amd64 host (Exec format
  # error). Search the binary directly for the embedded version constant —
  # Go links the `-X version.version=` string into the binary's data.
  # NB: do NOT pipe through `strings` — on an ELF object file GNU strings
  # defaults to scanning only loadable sections and can miss the Go version
  # string (observed false-negative on the build container's binutils).
  # `grep -a` reads the whole file as text: deterministic, no section logic.
  # Substring match (-F) is robust; false-positive risk for `X.Y.Z` in a
  # ~30MB binary is effectively zero.
  local nb="${OUT}/target/usr/bin/netbird"
  if [[ -x "$nb" ]]; then
    local nb_expected="${NETBIRD_TAG#v}"
    if grep -qaF "$nb_expected" "$nb" 2>/dev/null; then
      _check_pass "NetBird binary embeds version $nb_expected"
    else
      _check_fail "NetBird version $nb_expected not found in binary"
    fi
  else
    _check_fail "NetBird binary not found at $nb"
  fi

  # --- 3) Key systemd services enabled ---
  local svc_dir="${OUT}/target/etc/systemd/system"
  for svc in netbird.service; do
    if [[ -L "${svc_dir}/multi-user.target.wants/${svc}" ]] || [[ -f "${svc_dir}/multi-user.target.wants/${svc}" ]]; then
      _check_pass "Service enabled: $svc"
    else
      _check_fail "Service NOT enabled: $svc"
    fi
  done

  # --- 4) GA build ID stamped ---
  if [[ -f "${OUT}/target/etc/ga-build-id" ]]; then
    _check_pass "Build ID stamped: $(cat "${OUT}/target/etc/ga-build-id")"
  else
    _check_fail "ga-build-id not found"
  fi

  # --- 5) GA env config ---
  if [[ -f "${OUT}/target/etc/ga-env.conf" ]]; then
    local env_val
    env_val="$(grep '^GA_ENV=' "${OUT}/target/etc/ga-env.conf" | cut -d= -f2)"
    _check_pass "GA_ENV stamped: $env_val"
  else
    _check_fail "ga-env.conf not found"
  fi

  # --- 6) Data partition: check container images were loaded ---
  local hassio_dir="${OUT}/build/hassio-1.0.0"
  local version_json="${hassio_dir}/version.json"
  if [[ -f "$version_json" ]]; then
    # Check core image references greenautarky
    if grep -q "greenautarky" "$version_json"; then
      _check_pass "version.json references greenautarky core image"
    else
      _check_fail "version.json does NOT reference greenautarky"
    fi
    # Check core version is a pinned semver-ish tag (per-release strategy
    # since 2026-05-05 — no more rolling `latest`). Accept anything that
    # looks like `YYYY.MM.PATCH[.SUFFIX]` or `latest` (back-compat).
    local core_ver
    core_ver="$(jq -r '.core // "unknown"' "$version_json" 2>/dev/null)"
    if [[ "$core_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || [[ "$core_ver" == "latest" ]]; then
      _check_pass "Core image tag: $core_ver"
    else
      _check_fail "Core image tag invalid: '$core_ver' (expected pinned version or 'latest')"
    fi
  else
    _check_warn "version.json not found (normal for non-full builds)"
  fi

  # --- 7) Data partition size ---
  local data_img="${OUT}/images/data.ext4"
  if [[ -f "$data_img" ]]; then
    local data_sz_mb
    data_sz_mb="$(du -m "$data_img" | cut -f1)"
    _check_pass "Data partition: ${data_sz_mb}MB"
  fi

  # --- 8) os-release has GA fields ---
  local os_rel="${OUT}/target/etc/os-release"
  if [[ -f "$os_rel" ]] && grep -q "GA_BUILD_ID" "$os_rel"; then
    _check_pass "os-release has GA_BUILD_ID"
  else
    _check_warn "os-release missing GA_BUILD_ID"
  fi

  # --- 9) Frontend version resolved from core image labels ---
  if [[ "${GA_FRONTEND_PYVERSION:-unknown}" != "unknown" ]]; then
    _check_pass "Frontend version resolved: ${GA_FRONTEND_PYVERSION} (${GA_FRONTEND_VERSION})"
  else
    _check_warn "Frontend version not resolved (core image labels unavailable)"
  fi

  # --- Summary ---
  echo ""
  echo "  Results: $pass passed, $fail failed, $warn warnings"
  echo "=== Post-build integrity checks done ==="

  if (( fail > 0 )); then
    echo ""
    echo "ERROR: $fail integrity check(s) FAILED — review above output"
    return 1
  fi
}

rebuild_artifacts() {
  # Your tree has no 'images' target; use 'all' after target-finalize
  # Note: post-build.sh (called by target-finalize) writes os-release including
  # GA_BUILD_ID via GA_BUILD_TIMESTAMP and GA_ENV env vars exported by ga_build.sh
  make -C "$BUILDROOT_DIR" O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" "${MAKE_OVERRIDES[@]}" target-finalize
  make -C "$BUILDROOT_DIR" O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" "${MAKE_OVERRIDES[@]}" -j"$(nproc)" all
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

  # -------------------------------------------------------------------------
  # 5) Git repository pinning (all source trees)
  # -------------------------------------------------------------------------
  echo "[5/8] Pinning Git repositories..."

  # git refuses to read a repository owned by another uid ("detected dubious
  # ownership", safe.directory). The build container runs as root over a
  # builder-owned mount, so EVERY rev-parse below failed, get_git_info emitted
  # nothing, and the provenance record came out empty — reported only as a WARN.
  # `-c safe.directory=` and GIT_CONFIG_* are deliberately ignored for this
  # setting (otherwise the protection would be trivially bypassable), so a
  # global config entry is the only mechanism that works. Verified in the
  # container: -c fails, env fails, global config succeeds.
  local _repo_root="${SCRIPT_DIR%/scripts}"
  for _sd in "$_repo_root" "$BUILDROOT_DIR" "$BR2EXT_IHOST" "$BR2EXT_NETBIRD"; do
    [[ -n "$_sd" ]] && git config --global --add safe.directory "$_sd" 2>/dev/null || true
  done

  # Helper to get git info as JSON. Returns non-zero and says so when it cannot
  # read the repo — the old version returned success while emitting nothing,
  # which is how the separator ended up without an entry beside it.
  get_git_info() {
    local repo_path="$1"
    local repo_name="$2"
    local commit branch remote_url dirty

    if ! git -C "$repo_path" rev-parse --git-dir &>/dev/null; then
      echo "WARN: ${repo_name} (${repo_path}) is not a readable git repository — provenance for it will be MISSING" >&2
      return 1
    fi
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
  }

  # Emit the separator only once an entry actually exists. The old code decided
  # the comma from "the directory is present" and then called a helper that
  # could produce nothing, which is what made the JSON invalid.
  GA_PINS_ENTRIES=""
  add_repo_pin() {
    local _j
    _j="$(get_git_info "$1" "$2")" || return 0
    [[ -n "$_j" ]] || return 0
    if [[ -z "$GA_PINS_ENTRIES" ]]; then
      GA_PINS_ENTRIES="$_j"
    else
      GA_PINS_ENTRIES="${GA_PINS_ENTRIES},
${_j}"
    fi
  }

  # Collect git info for all relevant repos
  {
    echo "{"
    echo '  "generated": "'$(date '+%Y-%m-%dT%H:%M:%S')'",'
    echo '  "build_id": "'${GA_BUILD_TIMESTAMP}'",'
    echo '  "repositories": {'

    [[ -d "$_repo_root" ]]     && add_repo_pin "$_repo_root"     "ha-operating-system"
    [[ -d "$BUILDROOT_DIR" ]]  && add_repo_pin "$BUILDROOT_DIR"  "buildroot"
    [[ -d "$BR2EXT_IHOST" ]]   && add_repo_pin "$BR2EXT_IHOST"   "buildroot-ihost"
    [[ -d "$BR2EXT_NETBIRD" ]] && add_repo_pin "$BR2EXT_NETBIRD" "buildroot-external"

    printf '%s\n' "$GA_PINS_ENTRIES"

    echo "  },"

    # -------------------------------------------------------------------------
    # 5) Tarball/download hashes from Buildroot
    # -------------------------------------------------------------------------
    echo "[6/8] Collecting package download hashes..." >&2

    echo '  "packages": ['

    # Buildroot keeps .hash files next to each package RECIPE
    # (package/<name>/<name>.hash), NOT in the download directory. The previous
    # version searched $(BUILDROOT_DIR)/dl and $(OUT)/dl for "*.hash" — measured
    # 2026-07-30: zero matches in either, and zero in the real BR2_DL_DIR
    # (/cache/dl) too, which holds 528 downloaded files and no .hash at all.
    # So this list has always been emitted empty. It was not a wrong path; the
    # premise about where hashes live was wrong.
    #
    # This reports its own COVERAGE rather than silently emitting []. A
    # provenance list that cannot say how much of the build it covers is not
    # evidence — same lesson as the CVE scan that reported 0/208 packages and
    # was accepted as a clean result.
    local pkg_first=true
    local _matched=0 _unmatched=0
    while read -r bdir; do
      [[ -n "$bdir" ]] || continue
      local _full _name _hash=""
      _full="$(basename "$bdir")"
      # Strip trailing version-looking segments ("gcc-final-13.4.0" -> "gcc-final")
      _name="$_full"
      while [[ "$_name" == *-* && "${_name##*-}" =~ ^[0-9] ]]; do _name="${_name%-*}"; done
      for _cand in "${BUILDROOT_DIR}/package/${_name}/${_name}.hash" \
                   "${BUILDROOT_DIR}/package/${_name#host-}/${_name#host-}.hash" \
                   "${BR2EXT_IHOST}/package/${_name}/${_name}.hash" \
                   "${BR2EXT_NETBIRD}/package/${_name}/${_name}.hash"; do
        [[ -f "$_cand" ]] && { _hash="$_cand"; break; }
      done

      if [[ -n "$_hash" ]]; then
        _matched=$((_matched+1))
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
      "package": "${_name}",
      "build_dir": "${_full}",
      "filename": "${filename}",
      "algorithm": "${algo}",
      "hash": "${hash}"
    }
PKGEOF
        done < "$_hash"
      else
        _unmatched=$((_unmatched+1))
      fi
    done < <(find "${OUT}/build" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort) || true
    echo "Package hash coverage: ${_matched} matched, ${_unmatched} without a declared .hash (git-sourced packages have none by design)" >&2

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
    # 6) NetBird version (built via Buildroot)
    # -------------------------------------------------------------------------
    echo "[7/8] Recording NetBird version..." >&2

    echo '  "standalone_tools": {'
    echo '    "netbird": {'
    echo '      "version": "'${NETBIRD_TAG}'",'
    echo '      "source": "https://github.com/netbirdio/netbird",'
    echo '      "build": "buildroot golang-package"'
    echo '    }'
    echo '  },'

    # HA Core frontend version (resolved from core Docker image labels after build)
    echo '  "ha_core_frontend": {'
    echo '    "pyversion": "'${GA_FRONTEND_PYVERSION:-unknown}'",'
    echo '    "sha": "'${GA_FRONTEND_SHA:-unknown}'",'
    echo '    "branch_at_sha": "'${GA_FRONTEND_VERSION:-unknown}'"'
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

  # Validate the provenance record — FAIL CLOSED.
  #
  # This used to print "WARN: JSON validation failed" and carry on, so an
  # unparseable provenance record shipped as release evidence. It did: the
  # 2026-07-30 build emitted `"repositories": {\n,\n,\n}` — bare commas, no
  # entries — and the build reported success. A record nobody can parse proves
  # nothing about what went into the image, and the point of the file is to be
  # the answer to "what was this built from".
  #
  # jq missing is also a failure, not a pass: it means the check did not run,
  # and "did not run" must never read like "passed".
  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq not available — the provenance record CANNOT BE VERIFIED." >&2
    echo "       A build whose source-pins.json was never validated is not release evidence." >&2
    return 1
  fi
  if ! jq . "$pins_file" > "${pins_file}.tmp" 2>/dev/null; then
    echo "ERROR: source-pins.json is not valid JSON — the provenance record is unusable." >&2
    echo "       First 20 lines:" >&2
    head -20 "$pins_file" | sed 's/^/         /' >&2
    rm -f "${pins_file}.tmp"
    return 1
  fi
  mv "${pins_file}.tmp" "$pins_file"

  # Valid JSON is not the same as populated JSON. An empty repositories object
  # parses fine and still records nothing.
  local _nrepos
  _nrepos="$(jq -r '.repositories | length' "$pins_file" 2>/dev/null || echo 0)"
  if [[ "${_nrepos:-0}" -lt 1 ]]; then
    echo "ERROR: source-pins.json records ZERO source repositories." >&2
    echo "       Valid JSON, no content — this is the failure mode that hid for months." >&2
    echo "       Most likely cause: git cannot read the trees (safe.directory)." >&2
    return 1
  fi
  echo "Source pins validated: $pins_file (${_nrepos} repositories)"

  # Capture the evidence NOW, not at promotion time.
  #
  # images/configs/ is a FIXED path — cfg_dir="${OUT}/images/configs" — so every
  # build overwrites it. The previous build's provenance is gone the moment the
  # next build starts, which is sooner than any retention policy. Collecting at
  # promotion time would therefore collect whatever happened to be built last,
  # not what is being promoted.
  #
  # So a prod build files its own evidence under a version+build-id directory that
  # nothing overwrites and ota-cleanup.sh never touches. Promotion then only has
  # to publish the one directory matching the artefact it is promoting.
  #
  # Failure here does NOT fail the build: the image is already built and valid,
  # and refusing it over a bookkeeping step would be the wrong trade. It is loud
  # instead, and the promotion step is where absence becomes fatal.
  if [[ "$GA_ENV" == "prod" ]]; then
    local _ev_script="${SCRIPT_DIR}/ops/collect-release-evidence.sh"
    local _ev_root="${GA_EVIDENCE_ROOT:-/build/release-evidence}"
    local _ev_ver
    _ev_ver="$(sed -n 's/^gaos_release:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "${SCRIPT_DIR}/../version.yaml" 2>/dev/null | head -1)"
    if [[ -x "$_ev_script" && -n "$_ev_ver" ]]; then
      mkdir -p "${_ev_root}"
      if "$_ev_script" "$OUT" "$_ev_ver" "${_ev_root}/${GA_BUILD_TIMESTAMP}"; then
        echo "Release evidence filed: ${_ev_root}/${GA_BUILD_TIMESTAMP}/${_ev_ver}"
      else
        echo "WARNING: release-evidence collection FAILED — this build cannot be promoted until it is re-run" >&2
      fi
    else
      echo "WARNING: release-evidence collector or gaos_release missing — nothing filed for this build" >&2
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
# Enrich a CycloneDX SBOM in place with NVD vulnerability analysis.
#
# Uses Buildroot's own `support/scripts/cve-check`, which is the tool built for
# exactly this input: it matches on the `cpe` our SBOM carries (trivy keys on
# `purl`, which Buildroot does not emit — that is why the old trivy step scanned
# 0 of 208 packages), writes CycloneDX `analysis.state` (= VEX, natively), and
# preserves the per-package `<PKG>_IGNORE_CVES` entries Buildroot pre-seeds.
#
# On success a `ga:cve-check` marker is written into metadata.properties so
# downstream consumers can tell an ENRICHED SBOM from a bare one. Without that
# marker scan-cves.sh treats the OS scan as having no coverage and fails closed.
enrich_sbom_with_cves() {
  local sbom="$1"
  local cve_check="${BUILDROOT_DIR}/support/scripts/cve-check"
  local nvd_path="${GA_NVD_PATH:-${BUILDROOT_DIR}/dl/buildroot-nvd}"

  [[ -f "$sbom" ]] || return 0
  if [[ ! -f "$cve_check" ]]; then
    echo "WARN: cve-check not found at ${cve_check} — SBOM stays un-enriched"
    return 0
  fi

  echo "Enriching SBOM with NVD vulnerability analysis (cve-check)..."
  local nvd_args=(--nvd-path "$nvd_path")
  # The NVD mirror is a git clone; skip the refresh when explicitly asked
  # (offline builds) or when the mirror is already present and GA_NVD_OFFLINE=1.
  [[ "${GA_NVD_OFFLINE:-0}" == "1" ]] && nvd_args+=(--no-nvd-update)

  # Debian 11 build container ships Python 3.9, which cannot even import
  # cve-check (it annotates a return as `str | None`, evaluated eagerly before
  # 3.10). Route through the shim on old interpreters; call directly on new
  # ones so the stopgap disappears by itself once the image is upgraded.
  local runner=(python3 "$cve_check")
  if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
    local shim="${SCRIPT_DIR:-/build/scripts}/run-cve-check.py"
    if [[ -f "$shim" ]]; then
      echo "  python3 $(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])') < 3.10 — using run-cve-check.py shim"
      runner=(python3 "$shim" "$cve_check")
    else
      echo "WARN: python3 < 3.10 and no shim at ${shim} — cve-check cannot run"
      return 0
    fi
  fi

  local enriched="${sbom}.enriched"
  if "${runner[@]}" -i "$sbom" "${nvd_args[@]}" -o "$enriched" 2>&1 | tail -20; then
    if [[ -s "$enriched" ]] && jq -e '.components' "$enriched" >/dev/null 2>&1; then
      # Stamp the marker so a bare SBOM can never be mistaken for a scanned one.
      jq --arg ts "$(date -Iseconds)" \
         '.metadata.properties = ((.metadata.properties // [])
            + [{name:"ga:cve-check", value:$ts}])' \
         "$enriched" > "${enriched}.stamped" 2>/dev/null \
        && mv "${enriched}.stamped" "$sbom" \
        && rm -f "$enriched" \
        && echo "  SBOM enriched: $(jq '[.vulnerabilities // [] | .[] | select(.analysis.state == "exploitable")] | length' "$sbom" 2>/dev/null) exploitable, $(jq '[.vulnerabilities // []] | flatten | length' "$sbom" 2>/dev/null) total entries" \
        && return 0
    fi
    echo "WARN: cve-check produced no usable output — SBOM stays un-enriched"
  else
    echo "WARN: cve-check failed — SBOM stays un-enriched"
  fi
  rm -f "$enriched" "${enriched}.stamped"
  return 0
}

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
        enrich_sbom_with_cves "$cyclonedx"
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
    echo '    "netbird": { "version": "'${NETBIRD_TAG}'" }'
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

  # NOT installed into the target rootfs, on purpose.
  #
  # These used to be copied to /etc/ga-sbom-*.json. They never arrived: the copy
  # runs ~2 minutes AFTER rootfs.erofs is sealed (measured 2026-07-30, confirmed
  # absent on K31 after a fresh flash), so the code looked like it shipped an SBOM
  # and did not.
  #
  # Fixing the ordering was the obvious move and it is the wrong one. The SBOM's
  # home is $(OUT)/images — the artifact directory, next to configs/, legal-info/
  # and reports/ — and that copy was always intact. Shipping a second copy on the
  # device would add a component-and-version inventory to a read-only 300 MB
  # system partition, readable by anyone with filesystem access to a unit sitting
  # in a customer's home, to answer a question /etc/ga-build-id and GA_RELEASE
  # already answer precisely.
  #
  # So the dead copy is deleted rather than repaired. Operator decision 2026-07-30.

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
# haos_ihost-16.3.1.1.img.xz -> bos_ihost-16.3.1.1_dev_20260119123045.img.xz
# haos_ihost-16.3.1.1.raucb  -> bos_ihost-16.3.1.1_prod_20260119123045.raucb
rename_images_with_build_id() {
  local orig_base new_base
  orig_base="$(get_original_image_basename)" || return 1

  # Convert haos_ prefix to bos_ and append environment + timestamp
  local orig_name new_name
  local env_tag="${GA_ENV:-dev}"
  orig_name="$(basename "$orig_base")"
  new_name="${orig_name/haos_/bos_}_${env_tag}_${GA_BUILD_TIMESTAMP}"
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

  # Generate sha256 checksums for output images
  echo "Generating sha256 checksums..."
  for img in "${new_base}.img.xz" "${new_base}.img" "${new_base}.raucb"; do
    if [[ -f "$img" ]]; then
      sha256sum "$img" > "${img}.sha256"
      echo "  $(basename "${img}.sha256")"
    fi
  done

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

# Fail closed if this environment's trust anchor is missing, or if dev and prod
# resolve to the same file. Never auto-create one from the other.
require_base_ca

# Pre-flight: verify all container images exist in registries AND that the
# vibe_addons store versions are in lock-step with addon-images.json before
# building. Runs on full/partial AND on `update prod` (release builds): the
# addon-images.json pins DO change on incremental release builds, and a
# version mismatch there ships a device onto the wrong addon version silently
# (the 0.23.0 converge no-op and the 0.23.2 near-miss both slipped through
# precisely because `update prod` skipped this). `update dev` still skips it so
# fast dev iteration isn't gated on network. Set GA_SKIP_IMAGE_CHECK=1 to
# bypass when you KNOW the registry is fine but transiently unreachable.
if [[ "$MODE" == "full" || "$MODE" == "partial" || ( "$MODE" == "update" && "$GA_ENV" == "prod" ) ]]; then
  if [[ "${GA_SKIP_IMAGE_CHECK:-0}" == "1" ]]; then
    echo ""
    echo "=== Pre-flight image check SKIPPED (GA_SKIP_IMAGE_CHECK=1) ==="
    echo ""
  else
    echo ""
    echo "=== Pre-flight: checking container image availability + vibe_addons lock-step ==="
    if [[ -f "${SCRIPT_DIR}/check-images.sh" ]]; then
      set +e
      # STRICT here and only here. An add-on source repo that has just merged a
      # bump legitimately leads the pin until its image finishes publishing, so
      # source drift is advisory in the PR check — but a build turns this tree
      # into an image someone flashes, and shipping a pin that is behind its
      # source is how five ga_manager releases became undeliverable
      # (2026-07-29). Override with GA_SOURCE_DRIFT_STRICT=0 for a deliberate
      # build of an older pin.
      GA_SOURCE_DRIFT_STRICT="${GA_SOURCE_DRIFT_STRICT:-1}" "${SCRIPT_DIR}/check-images.sh"
      _img_rc=$?
      set -e
      case "$_img_rc" in
        0)
          echo "Pre-flight passed."
          ;;
        2)
          # Private image could not be verified for lack of credentials. Since
          # 2026-07-29 the ga_manager packages are private; the builder pulls
          # them via /root/.docker/config.json. Exit 2 means that credential is
          # gone or expired — the build WOULD fail later at `skopeo copy`, just
          # 20 minutes deeper in. Stop here instead.
          echo "ERROR: Pre-flight could not verify private image(s) — no registry credentials." >&2
          echo "  The build would fail later at skopeo copy. Log in first:" >&2
          echo "    skopeo login ghcr.io -u <user> -p <read:packages token>" >&2
          echo "  Run: ./scripts/check-images.sh   (for details)" >&2
          exit 1
          ;;
        *)
          echo "ERROR: Pre-flight image check failed. Fix missing images / version drift before building." >&2
          echo "  Run: ./scripts/check-images.sh   (for details)" >&2
          echo "  Or set GA_SKIP_IMAGE_CHECK=1 if the registry is only transiently unreachable." >&2
          exit 1
          ;;
      esac
    else
      echo "WARNING: check-images.sh not found, skipping pre-flight image check."
    fi
    echo ""
  fi
fi

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
  # Force rebuild of GA config packages so changed configs/services are picked up
  # (Buildroot doesn't track overlay/config file changes as package dependencies)
  make O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" \
    telegraf-dirclean fluent-bit-config-dirclean 2>/dev/null || true
  # Force hassio to re-check container image digests from registry
  # Without this, Buildroot skips the fetch step and uses stale cached tars
  # (same Docker tag can have new content after a Core/Frontend rebuild)
  #
  # .stamp_configured BELONGS IN THIS LIST, and its absence cost a release.
  #
  # HASSIO_CONFIGURE_CMDS is where version.json is written:
  #     curl {HASSIO_VERSION_URL}{channel}.json | jq '.core = …' > $(@D)/version.json
  # and that file is the ONLY carrier of the channel-resolved Supervisor, Core
  # and plugin versions into the image. Buildroot guards CONFIGURE_CMDS with
  # $(@D)/.stamp_configured (package/pkg-generic.mk, $(2)_TARGET_CONFIGURE), so
  # on any tree that already has one, configure never re-runs and yesterday's
  # version.json — yesterday's CHANNEL — is reused verbatim.
  #
  # Measured on BOSv1.3.0-rc6, 2026-08-24: the defconfig selected
  # BR2_PACKAGE_HASSIO_CHANNEL_BETA and ga_output/.config carried it, but the
  # build reused a version.json dated 2026-08-20 saying "channel": "stable".
  # The image shipped the stable component set (supervisor 2025.11.4.6,
  # upstream armv7-hassio-dns 2025.08.0, cli 2025.10.0) while its own
  # updater.json declared beta — because the channel string reaching
  # create-data-partition.sh comes straight from make and DID follow the
  # defconfig. Two channel paths, one cached and one live, and nothing compared
  # them. Unblocked by deleting the tree on the builder by hand.
  #
  # Second-order: hassio.mk's own version.json validation (the latest/registry/
  # supervisor-pin block) also lives inside CONFIGURE_CMDS, so on a reused tree
  # it does not run either. A check that is skipped reads exactly like a check
  # that passed.
  #
  # Cost of adding it: one curl + one jq. The extracted source is a local rsync
  # (HASSIO_SITE_METHOD = local), the container tars live in HASSIO_DL_DIR, and
  # the build/install stamps below are dropped on every update build anyway.
  rm -f "${OUT}/build/hassio-1.0.0/.stamp_configured" \
        "${OUT}/build/hassio-1.0.0/.stamp_built" \
        "${OUT}/build/hassio-1.0.0/.stamp_images_installed" \
        "${OUT}/build/hassio-1.0.0/.stamp_installed" \
        "${OUT}/build/hassio-1.0.0/.stamp_target_installed" 2>/dev/null || true
  # Clean old container tars to avoid disk bloat (stale digests accumulate)
  rm -rf "${OUT}/build/hassio-1.0.0/images" 2>/dev/null || true
  echo "Cleared hassio stamps (incl. .stamp_configured, so version.json is refetched"
  echo "for the channel the defconfig declares) + old container tars"

else
  echo "Usage: $0 [full|partial|kernel|update|dev|prod] [dev|prod]"
  echo "       $0 dev   # shorthand for 'update dev'"
  echo "       $0 prod  # shorthand for 'update prod'"
  exit 1
fi

# Initialize build logging (after configure, so $OUT/images/ survives rm -rf in full mode)
start_build_log
log_build_step "Configure ($MODE mode)" "completed"

# 2) Build full system (including NetBird via Buildroot golang-package)
log_build_step "Buildroot main build"
make O="$OUT" BR2_EXTERNAL="$BR2_EXTERNAL_PATH" "${MAKE_OVERRIDES[@]}" -j"$(nproc)" 2>&1 | tee -a "$BUILD_LOG"

# 3) Inject build ID and regenerate final artifacts
log_build_step "Write build ID"
write_build_id_into_target

# 3a) Resolve frontend version from core image labels and stamp into rootfs
log_build_step "Resolve frontend version"
resolve_frontend_version
stamp_frontend_version_into_target

log_build_step "Verify outputs"
verify_outputs
log_build_step "Rebuild artifacts"
rebuild_artifacts

# 6) Rename images with ga-build-id timestamp suffix
log_build_step "Rename images"
rename_images_with_build_id

# 6a) Verify /etc/ga-release was actually stamped with what we resolved
log_build_step "Post-bake assertion: /etc/ga-release stamped"
assert_ga_release_stamped

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
  #    Auto-enabled for prod builds; for dev builds, set GA_LEGAL_INFO=true to enable
  if [[ "${GA_LEGAL_INFO:-false}" == "true" ]] || [[ "$GA_ENV" == "prod" ]]; then
    log_build_step "Archive legal-info"
    archive_legal_info
  else
    echo "Skipping legal-info archive (set GA_LEGAL_INFO=true to enable)"
  fi

  # 10) Generate Software Bill of Materials (SBOM)
  log_build_step "Generate SBOM"
  generate_sbom 2>&1 | tee -a "$BUILD_LOG"

  # 11) CVE scan of SBOM — coverage-verified, fail-closed on prod
  #
  # Delegated to scripts/scan-cves.sh so the coverage assertion lives in ONE
  # place. Until 2026-07-28 this step ran trivy directly and printed "CVE scan
  # complete" while scanning 0 of 208 OS packages (trivy has no matcher for
  # `family="buildroot"`), and the empty report was shipped as release evidence.
  # A scan without coverage now exits 2 and, on prod, fails the build — the same
  # fail-closed rule as the root password (#239).
  mkdir -p "${OUT}/images/reports"
  if command -v trivy &>/dev/null && [[ -f "${OUT}/images/sbom-cyclonedx.json" ]]; then
    log_build_step "CVE scan (SBOM)"
    # Trivy doesn't support CycloneDX component type "firmware" — patch to "operating-system"
    if command -v jq &>/dev/null; then
      jq '(.metadata.component.type) = "operating-system"' "${OUT}/images/sbom-cyclonedx.json" \
        > "${OUT}/images/sbom-cyclonedx.json.tmp" 2>/dev/null \
        && mv "${OUT}/images/sbom-cyclonedx.json.tmp" "${OUT}/images/sbom-cyclonedx.json"
    else
      sed -i 's/"type": "firmware"/"type": "operating-system"/' "${OUT}/images/sbom-cyclonedx.json"
    fi
    echo "Scanning SBOM for CRITICAL/HIGH vulnerabilities..."
    _cve_rc=0
    # GA_ENV is already exported (set -a at the top, plus the explicit export at
    # the GA_BUILD_TIMESTAMP line); passed again here so the dependency is
    # visible at the call site rather than implied 1700 lines away.
    #
    # NO `|| true` on this pipeline: appending it makes `true` the last executed
    # command, which RESETS PIPESTATUS to (0) — so `_cve_rc` read 0 even when
    # scan-cves.sh exited 2, and the prod abort below never fired. Verified live
    # on the 2026-07-28 bake: the log shows "Result: BROKEN SCAN (exit 2)"
    # immediately followed by "CVE scan complete". `set +e` is the correct way
    # to survive a non-zero exit while keeping PIPESTATUS intact.
    set +e
    GA_SBOM="${OUT}/images/sbom-cyclonedx.json" \
    OUTPUT_DIR="${OUT}/images/reports" \
    GA_ENV="${GA_ENV:-dev}" \
      "${SCRIPT_DIR:-/build/scripts}/scan-cves.sh" --sbom --severity CRITICAL,HIGH \
        2>&1 | tee "${OUT}/images/reports/cve-scan-sbom.txt"
    _cve_rc=${PIPESTATUS[0]}
    set -e
    if [[ "$_cve_rc" -eq 2 ]]; then
      # Broken scan — never report this as clean.
      if [[ "${GA_ENV:-dev}" == "prod" ]]; then
        echo "ERROR: OS CVE scan produced no coverage — refusing to build a prod image"
        echo "       An empty CVE report must not ship as release evidence. See KB #172."
        exit 1
      fi
      echo "WARN: OS CVE scan produced no coverage (non-prod build — continuing)"
    elif [[ "$_cve_rc" -eq 0 ]]; then
      echo "CVE scan complete — results in ${OUT}/images/reports/cve-scan-sbom.txt"
    else
      echo "CVE scan found vulnerabilities — see ${OUT}/images/reports/cve-scan-sbom.txt"
    fi

    # 11b) Scan downloaded container image tars (covers private GHCR images)
    _cve_images_dir="$(ls -d "${OUT}/build/hassio-"*/images 2>/dev/null | head -n 1 || true)"
    if [[ -d "$_cve_images_dir" ]]; then
      echo ""
      echo "Scanning container image tars for CRITICAL/HIGH vulnerabilities..."
      _cve_scan_file="${OUT}/images/reports/cve-scan-containers.txt"
      : > "$_cve_scan_file"
      _cve_img_total=0 _cve_img_clean=0 _cve_img_findings=0 _cve_img_blind=0 _cve_img_unscannable=0
      for tarball in "$_cve_images_dir"/*.tar; do
        [[ -f "$tarball" ]] || continue
        _cve_img_name="$(basename "$tarball" .tar)"
        _cve_img_total=$((_cve_img_total + 1))
        echo "  Scanning: ${_cve_img_name}..." | tee -a "$_cve_scan_file"
        # Two defects fixed here at once, both found 2026-08-24:
        #
        # 1. NO COVERAGE ASSERTION. trivy returns success having evaluated
        #    nothing when it has no matcher for the image's package family, so
        #    an empty table counted as "clean". Same blindness scan-cves.sh was
        #    fixed for on 2026-07-28 — this copy simply never got the fix.
        #    `--list-all-pkgs --format json` makes the verdict checkable.
        #
        # 2. THE COUNTER WAS MEANINGLESS. It ran
        #      grep -cE "CRITICAL|HIGH" "$_cve_scan_file"
        #    over the ACCUMULATING report file, which every previous image had
        #    already appended to. So once ONE image had a finding, every image
        #    after it counted as "with findings" — and the "clean" number was
        #    whatever happened to come first. Per-image JSON, counted per image.
        _cve_json="${_cve_scan_file%.txt}-${_cve_img_name}.json"
        if trivy image --severity CRITICAL,HIGH --list-all-pkgs --format json \
             --output "$_cve_json" --input "$tarball" 2>>"$_cve_scan_file"; then
          _cve_pkgs=$(jq '[.Results[]? | select(.Class == "os-pkgs") | .Packages // []] | flatten | length' "$_cve_json" 2>/dev/null || echo 0)
          _cve_count=$(jq '[.Results[]?.Vulnerabilities // []] | flatten | length' "$_cve_json" 2>/dev/null || echo 0)
          if [[ "${_cve_pkgs:-0}" -eq 0 ]]; then
            echo "    ERROR: BLIND — 0 OS packages evaluated. An empty report is NOT a clean one." | tee -a "$_cve_scan_file"
            _cve_img_blind=$((_cve_img_blind + 1))
          elif [[ "${_cve_count:-0}" -gt 0 ]]; then
            echo "    FOUND: ${_cve_count} CRITICAL/HIGH across ${_cve_pkgs} package(s)" | tee -a "$_cve_scan_file"
            trivy image --severity CRITICAL,HIGH --format table --input "$tarball" 2>&1 | tee -a "$_cve_scan_file"
            _cve_img_findings=$((_cve_img_findings + 1))
          else
            echo "    CLEAN: 0 CRITICAL/HIGH across ${_cve_pkgs} evaluated package(s)" | tee -a "$_cve_scan_file"
            _cve_img_clean=$((_cve_img_clean + 1))
          fi
        else
          echo "    WARN: could not scan ${_cve_img_name}" | tee -a "$_cve_scan_file"
          _cve_img_unscannable=$((_cve_img_unscannable + 1))
        fi
      done
      echo "" | tee -a "$_cve_scan_file"
      echo "Container image scan: ${_cve_img_clean} clean, ${_cve_img_findings} with findings, ${_cve_img_blind} BLIND, ${_cve_img_unscannable} unscannable (${_cve_img_total} total)" | tee -a "$_cve_scan_file"
      # Deliberately still a REPORT, not a gate — it always was, and turning it
      # into one is a separate decision with its own blast radius (it would fail
      # a prod bake). What changes today is that the report can no longer make a
      # claim it did not measure. If this line ever shows BLIND > 0, the honest
      # reading is "we do not know", not "clean".
      if [[ "$_cve_img_blind" -gt 0 ]]; then
        echo "ERROR: ${_cve_img_blind} container image(s) were scanned with ZERO package coverage — those results are UNKNOWN, not clean" | tee -a "$_cve_scan_file"
      fi
    fi
  elif [[ "${GA_ENV:-dev}" == "prod" ]]; then
    # Fail closed: a prod release must not ship without a scanned SBOM.
    command -v trivy &>/dev/null \
      || { echo "ERROR: trivy not installed — a prod build cannot skip the CVE scan"; exit 1; }
    echo "ERROR: no SBOM at ${OUT}/images/sbom-cyclonedx.json — a prod build must produce one"
    exit 1
  else
    echo "Skipping CVE scan (trivy not installed or no SBOM)"
  fi
else
  echo "Skipping post-build artifacts for dev build (SBOMs, config archive, provisioning)"
  echo "  Use 'prod' environment for full artifact generation"
fi

# Post-build integrity checks
log_build_step "Build integrity checks"
verify_build_integrity

# RAUC keyring audit — assert the trust anchors that actually landed in the
# image, not the ones rauc.sh intended to put there.
#
# Fail-closed on prod, same rule as the root password (#239) and the CVE scan
# coverage assertion. A wrong keyring is expensive to repair: /etc/rauc is not
# overlay-backed, and `rauc install` verifies against the keyring the device
# already runs — so the supported update path is precisely what a bad keyring
# blocks. What is left is a manual raw write to the inactive slot over SSH,
# once per device (docs/RAUC-KEYRING.md). Exit 2 means the audit could not run
# at all and is fatal everywhere; a green build must never be able to mean
# "not checked". [Odoo #624]
keyring_audit="${SCRIPT_DIR}/verify-rauc-keyring.sh"
if [[ -x "$keyring_audit" ]]; then
  log_build_step "RAUC keyring audit"
  set +e
  REPO_ROOT="${SCRIPT_DIR%/scripts}" GA_ENV="$GA_ENV" "$keyring_audit" "$OUT" 2>&1 | tee -a "$BUILD_LOG"
  _kr_rc=${PIPESTATUS[0]}
  set -e
  if (( _kr_rc == 2 )); then
    echo "ERROR: RAUC keyring audit could not run (exit 2) — refusing to ship an unverified trust set"
    exit 1
  elif (( _kr_rc != 0 )); then
    if [[ "$GA_ENV" == "prod" ]]; then
      echo "ERROR: RAUC keyring audit found a trust-anchor problem — a prod image must not ship it"
      exit 1
    fi
    echo "WARNING: RAUC keyring audit findings above (non-fatal for GA_ENV=${GA_ENV}; a prod build WILL fail here)"
  fi
else
  echo "ERROR: ${keyring_audit} missing or not executable — the keyring trust set would ship unverified"
  exit 1
fi

# Run build-time test suite if available
build_tests="/build/tests/ga_tests/run_build_tests.sh"
if [[ -x "$build_tests" ]]; then
  log_build_step "Build-time test suite"
  "$build_tests" "$OUT" 2>&1 | tee -a "$BUILD_LOG"
else
  echo "Build test suite not found at $build_tests (skipping)"
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
echo "  NetBird:        ${nb_ver}"
echo "  HA Core FE:     ${GA_FRONTEND_PYVERSION:-unknown} (${GA_FRONTEND_VERSION:-unknown})"
echo ""

echo "  Output images (this build):"
# Only show images from this build (matching current timestamp)
for f in "${OUT}/images/"*"${GA_BUILD_TIMESTAMP}"*.img.xz "${OUT}/images/"*"${GA_BUILD_TIMESTAMP}"*.raucb; do
  if [[ -f "$f" ]]; then
    sz="$(du -h "$f" | cut -f1)"
    echo "    $(basename "$f")  ${sz}"
    if [[ -f "${f}.sha256" ]]; then
      sha="$(cut -d' ' -f1 "${f}.sha256")"
      echo "      sha256: ${sha}"
    fi
  fi
done
echo ""

echo "  SBOMs:"
[[ -f "${OUT}/images/sbom-cyclonedx.json" ]] && echo "    sbom-cyclonedx.json   (Buildroot packages, CycloneDX 1.6)"
[[ -f "${OUT}/images/sbom-containers.json" ]] && echo "    sbom-containers.json  (Container images + standalone tools)"
echo ""
echo "  Reports:  ${OUT}/images/reports/"
if [[ -f "${OUT}/images/reports/cve-scan-sbom.txt" ]]; then
  cve_count=$(grep -c "CRITICAL\|HIGH" "${OUT}/images/reports/cve-scan-sbom.txt" 2>/dev/null | head -1 | tr -cd '0-9' || echo "0")
  cve_count="${cve_count:-0}"
  echo "    cve-scan-sbom.txt         (${cve_count} CRITICAL/HIGH findings)"
fi
if [[ -f "${OUT}/images/reports/cve-scan-containers.txt" ]]; then
  cve_img_summary=$(tail -1 "${OUT}/images/reports/cve-scan-containers.txt" 2>/dev/null || echo "")
  echo "    cve-scan-containers.txt   (${cve_img_summary})"
fi
[[ -f "${OUT}/images/reports/build-report.html" ]] && echo "    build-report.html         (open in browser)"
echo ""

echo "  Configs:  ${OUT}/images/configs/"
if [[ "${GA_PROVISIONING:-false}" == "true" ]]; then
  echo "  Provisioning image: enabled"
else
  echo "  Provisioning image: skipped (GA_PROVISIONING=true to enable)"
fi
if [[ "${GA_LEGAL_INFO:-false}" == "true" ]] || [[ "$GA_ENV" == "prod" ]]; then
  echo "  Legal info: ${OUT}/images/legal-info/"
else
  echo "  Legal info: skipped (auto-enabled for prod, or set GA_LEGAL_INFO=true)"
fi
echo ""
echo "  Build log: ${BUILD_LOG}"
echo ""

# Flash hint — show the command to flash the image to an SD card
img_xz="$(ls "${OUT}/images/"*"${GA_BUILD_TIMESTAMP}"*.img.xz 2>/dev/null | head -n 1 || true)"
if [[ -n "$img_xz" ]]; then
  echo "  To flash this image:"
  echo "    ./scripts/verify-sd.sh --all $(basename "$img_xz")"
fi

# Generate HTML build report
_report="${OUT}/images/reports/build-report.html"
_img_name="$(basename "$img_xz" 2>/dev/null || echo "none")"
_img_size="$(du -h "$img_xz" 2>/dev/null | cut -f1 || echo "N/A")"
_img_sha="$(cut -d' ' -f1 "${img_xz}.sha256" 2>/dev/null || echo "N/A")"
_raucb="$(ls "${OUT}/images/"*"${GA_BUILD_TIMESTAMP}"*.raucb 2>/dev/null | head -n 1 || true)"
_raucb_name="$(basename "$_raucb" 2>/dev/null || echo "none")"
_raucb_size="$(du -h "$_raucb" 2>/dev/null | cut -f1 || echo "N/A")"
_cve_sbom_count=$(grep -c "CRITICAL\|HIGH" "${OUT}/images/reports/cve-scan-sbom.txt" 2>/dev/null | head -1 | tr -cd '0-9' || echo "0")
_cve_sbom_count="${_cve_sbom_count:-0}"
_cve_container_summary=$(tail -1 "${OUT}/images/reports/cve-scan-containers.txt" 2>/dev/null || echo "N/A")
_build_tests_pass=$(grep -cE '^\s*PASS' "$BUILD_LOG" 2>/dev/null | head -1 | tr -cd '0-9' || echo "0")
_build_tests_pass="${_build_tests_pass:-0}"
_build_tests_fail=$(grep -cE '^\s*FAIL' "$BUILD_LOG" 2>/dev/null | head -1 | tr -cd '0-9' || echo "0")
_build_tests_fail="${_build_tests_fail:-0}"
_build_tests_skip=$(grep -cE '^\s*SKIP' "$BUILD_LOG" 2>/dev/null | head -1 | tr -cd '0-9' || echo "0")
_build_tests_skip="${_build_tests_skip:-0}"
_source_pins="$(cat "${OUT}/images/configs/source-pins.json" 2>/dev/null || echo "{}")"
_build_duration="$(grep 'Total build time' "$BUILD_LOG" 2>/dev/null | tail -1 || echo "unknown")"

# Disk image sizes (uncompressed)
_data_ext4_size="$(du -h "${OUT}/images/data.ext4" 2>/dev/null | cut -f1 || echo "N/A")"
_rootfs_size="$(du -h "${OUT}/images/rootfs.erofs" 2>/dev/null | cut -f1 || echo "N/A")"
_boot_size="$(du -h "${OUT}/images/boot.vfat" 2>/dev/null | cut -f1 || echo "N/A")"
_disk_img="$(ls "${OUT}/images/haos_"*.img 2>/dev/null | head -n 1 || true)"
_disk_img_size="$(du -h "$_disk_img" 2>/dev/null | cut -f1 || echo "N/A")"

# Container image sizes (tars in hassio build dir)
_container_rows=""
_container_total=0
_images_dir="${OUT}/build/hassio-1.0.0/images"
if [[ -d "$_images_dir" ]]; then
  while IFS= read -r tarfile; do
    _tar_name="$(basename "$tarfile" .tar)"
    # Clean up name: replace _ with / for readability, trim sha256 digest
    _tar_display="$(echo "$_tar_name" | sed 's/@sha256_.*//' | sed 's|_|/|')"
    _tar_bytes="$(stat -c%s "$tarfile" 2>/dev/null || echo 0)"
    _tar_human="$(du -h "$tarfile" 2>/dev/null | cut -f1 || echo "?")"
    _container_total=$(( _container_total + _tar_bytes ))
    _container_rows="${_container_rows}<tr><td class=\"mono\">${_tar_display}</td><td>${_tar_human}</td></tr>"
  done < <(ls -S "$_images_dir"/*.tar 2>/dev/null)
fi
_container_total_human="$(echo "$_container_total" | awk '{printf "%.1f GB", $1/1024/1024/1024}')"

cat > "$_report" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>GA OS Build Report — ${GA_BUILD_TIMESTAMP}</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 900px; margin: 40px auto; padding: 0 20px; color: #333; background: #fafafa; }
  h1 { color: #2e7d32; border-bottom: 3px solid #2e7d32; padding-bottom: 10px; }
  h2 { color: #1b5e20; margin-top: 30px; }
  table { border-collapse: collapse; width: 100%; margin: 10px 0; }
  th, td { padding: 8px 12px; text-align: left; border: 1px solid #ddd; }
  th { background: #e8f5e9; }
  .pass { color: #2e7d32; font-weight: bold; }
  .fail { color: #c62828; font-weight: bold; }
  .skip { color: #f57f17; }
  .warn { color: #e65100; }
  .mono { font-family: 'Fira Code', 'Consolas', monospace; font-size: 0.9em; }
  .badge { display: inline-block; padding: 4px 12px; border-radius: 4px; color: white; font-weight: bold; font-size: 0.85em; }
  .badge-pass { background: #2e7d32; }
  .badge-fail { background: #c62828; }
  .badge-warn { background: #e65100; }
  .sha { font-size: 0.75em; color: #666; word-break: break-all; }
  pre { background: #f5f5f5; padding: 12px; border-radius: 4px; overflow-x: auto; font-size: 0.85em; }
  .summary-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 15px; }
  .summary-card { background: white; border: 1px solid #ddd; border-radius: 8px; padding: 15px; }
  .footer { margin-top: 40px; padding-top: 15px; border-top: 1px solid #ddd; color: #999; font-size: 0.85em; }
</style>
</head>
<body>
<h1>GA OS Build Report</h1>

<div class="summary-grid">
<div class="summary-card">
  <h3>Build Info</h3>
  <table>
  <tr><td>Build ID</td><td class="mono">${GA_BUILD_TIMESTAMP}</td></tr>
  <tr><td>Date</td><td>${GA_BUILD_DATE:-$(date '+%Y-%m-%d %H:%M:%S')}</td></tr>
  <tr><td>Environment</td><td><span class="badge badge-${GA_ENV}">${GA_ENV}</span></td></tr>
  <tr><td>Mode</td><td>${MODE}</td></tr>
  <tr><td>Duration</td><td>${_build_duration}</td></tr>
  </table>
</div>
<div class="summary-card">
  <h3>Versions</h3>
  <table>
  <tr><td>Kernel</td><td class="mono">${kernel_ver}</td></tr>
  <tr><td>Buildroot</td><td class="mono">${buildroot_ver}</td></tr>
  <tr><td>NetBird</td><td class="mono">${nb_ver}</td></tr>
  <tr><td>HA Core FE</td><td class="mono">${GA_FRONTEND_PYVERSION:-unknown}</td></tr>
  <tr><td>Defconfig</td><td class="mono">${DEFCONFIG}</td></tr>
  </table>
</div>
</div>

<h2>Output Images</h2>
<table>
<tr><th>File</th><th>Size</th><th>SHA256</th></tr>
<tr><td class="mono">${_img_name}</td><td>${_img_size}</td><td class="sha">${_img_sha}</td></tr>
<tr><td class="mono">${_raucb_name}</td><td>${_raucb_size}</td><td class="sha">$(cut -d' ' -f1 "${_raucb}.sha256" 2>/dev/null || echo "N/A")</td></tr>
</table>

<h2>Disk Layout</h2>
<table>
<tr><th>Partition / Image</th><th>Size</th></tr>
<tr><td>Total disk image (uncompressed)</td><td><strong>${_disk_img_size}</strong></td></tr>
<tr><td>rootfs.erofs</td><td>${_rootfs_size}</td></tr>
<tr><td>boot.vfat</td><td>${_boot_size}</td></tr>
<tr><td>data.ext4</td><td>${_data_ext4_size}</td></tr>
</table>

<h2>Pre-baked Container Images</h2>
<table>
<tr><th>Image</th><th>Size (tar)</th></tr>
${_container_rows}
<tr><td><strong>Total</strong></td><td><strong>${_container_total_human}</strong></td></tr>
</table>

<h2>Build Tests</h2>
<p>
  <span class="badge badge-pass">${_build_tests_pass} PASS</span>
  <span class="badge badge-fail">${_build_tests_fail} FAIL</span>
  <span class="badge badge-warn">${_build_tests_skip} SKIP</span>
</p>
$(if [[ "$_build_tests_fail" -gt 0 ]]; then
  echo "<h3 class='fail'>Failed Tests</h3><pre>"
  grep -E '^\s*FAIL' "$BUILD_LOG" 2>/dev/null
  echo "</pre>"
fi)

<h2>CVE Scan</h2>
<table>
<tr><th>Target</th><th>Findings (CRITICAL/HIGH)</th><th>Status</th></tr>
<tr>
  <td>OS Packages (SBOM)</td>
  <td>${_cve_sbom_count}</td>
  <td>$(if [[ "$_cve_sbom_count" == "0" ]]; then echo '<span class="pass">CLEAN</span>'; elif [[ "$_cve_sbom_count" == "N/A" ]]; then echo '<span class="skip">SKIPPED</span>'; else echo '<span class="fail">FINDINGS</span>'; fi)</td>
</tr>
<tr>
  <td>Container Images (13)</td>
  <td colspan="2">${_cve_container_summary}</td>
</tr>
</table>

<h2>Source Pins</h2>
<pre>$(echo "$_source_pins" | python3 -m json.tool 2>/dev/null || echo "$_source_pins")</pre>

<h2>Artifacts</h2>
<table>
<tr><th>File</th><th>Description</th></tr>
<tr><td class="mono">build.log.xz</td><td>Complete build log (compressed)</td></tr>
<tr><td class="mono">configs/source-pins.json</td><td>Git SHAs of all source repositories</td></tr>
<tr><td class="mono">configs/container-images.lock.json</td><td>Container image digests</td></tr>
$(if [[ -f "${OUT}/images/sbom-cyclonedx.json" ]]; then echo '<tr><td class="mono">sbom-cyclonedx.json</td><td>CycloneDX 1.6 SBOM (OS packages)</td></tr>'; fi)
$(if [[ -f "${OUT}/images/sbom-containers.json" ]]; then echo '<tr><td class="mono">sbom-containers.json</td><td>Container image inventory</td></tr>'; fi)
$(if [[ -f "${OUT}/images/reports/cve-scan-sbom.txt" ]]; then echo '<tr><td class="mono">cve-scan-sbom.txt</td><td>Trivy SBOM scan results</td></tr>'; fi)
$(if [[ -f "${OUT}/images/reports/cve-scan-containers.txt" ]]; then echo '<tr><td class="mono">cve-scan-containers.txt</td><td>Trivy container scan results</td></tr>'; fi)
$(if [[ -d "${OUT}/images/legal-info" ]]; then echo '<tr><td class="mono">legal-info/</td><td>License manifests + source archive</td></tr>'; fi)
</table>

<div class="footer">
  Generated by ga_build.sh | GreenAutarky GmbH | $(date -Iseconds)
</div>
</body>
</html>
HTMLEOF

echo ""
echo "  Build report: ${_report}"
