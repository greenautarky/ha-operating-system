#!/bin/bash
# Build-time test runner — verifies build output tree after ga_build.sh
# Usage: run_build_tests.sh <output_dir>
#   e.g.: run_build_tests.sh /build/ga_output
#
# Exit code: number of failures (0 = all pass)
set -u

OUT="${1:?Usage: $0 <output_dir>}"
TARGET="${OUT}/target"

pass=0 fail=0 skip=0

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' RESET='\033[0m'
[[ -t 1 ]] || { GREEN=''; RED=''; YELLOW=''; RESET=''; }

_pass() { echo -e "${GREEN}  PASS${RESET}  $1"; pass=$((pass+1)); }
_fail() { echo -e "${RED}  FAIL${RESET}  $1"; fail=$((fail+1)); }
_skip() { echo -e "${YELLOW}  SKIP${RESET}  $1 ($2)"; skip=$((skip+1)); }

echo ""
echo "=== Build-time verification tests ==="
echo "  Output: $OUT"
echo ""

# =========================================================================
# Config files on rootfs
# =========================================================================
echo "--- Config files ---"

# CFG-01: telegraf.conf exists
[[ -f "${TARGET}/etc/telegraf/telegraf.conf" ]] \
  && _pass "CFG-01: telegraf.conf exists on rootfs" \
  || _fail "CFG-01: telegraf.conf missing"

# CFG-02: telegraf.conf has device_label
grep -q 'device_label' "${TARGET}/etc/telegraf/telegraf.conf" 2>/dev/null \
  && _pass "CFG-02: telegraf.conf has device_label tag" \
  || _fail "CFG-02: telegraf.conf missing device_label"

# CFG-03: telegraf.conf has uuid
grep -q 'uuid' "${TARGET}/etc/telegraf/telegraf.conf" 2>/dev/null \
  && _pass "CFG-03: telegraf.conf has uuid tag" \
  || _fail "CFG-03: telegraf.conf missing uuid"

# CFG-06: telegraf.service has safe default
grep -q 'DEVICE_LABEL' "${TARGET}/etc/systemd/system/telegraf.service" 2>/dev/null \
  && _pass "CFG-06: telegraf.service has DEVICE_LABEL" \
  || _fail "CFG-06: telegraf.service missing DEVICE_LABEL"

# CFG-07: fluent-bit.conf exists
[[ -f "${TARGET}/etc/fluent-bit/fluent-bit.conf" ]] \
  && _pass "CFG-07: fluent-bit.conf exists on rootfs" \
  || _fail "CFG-07: fluent-bit.conf missing"

# CFG-08: fluent-bit.conf has device_label in record_modifier
grep -q 'device_label' "${TARGET}/etc/fluent-bit/fluent-bit.conf" 2>/dev/null \
  && _pass "CFG-08: fluent-bit.conf has device_label" \
  || _fail "CFG-08: fluent-bit.conf missing device_label"

# CFG-11: fluent-bit.service has safe default
FB_SVC="${TARGET}/usr/lib/systemd/system/fluent-bit.service"
grep -q 'DEVICE_LABEL' "$FB_SVC" 2>/dev/null \
  && _pass "CFG-11: fluent-bit.service has DEVICE_LABEL" \
  || _fail "CFG-11: fluent-bit.service missing DEVICE_LABEL"

# CFG-13/14: /etc/hosts has fallback entries
grep -q 'influx.greenautarky.com' "${TARGET}/etc/hosts" 2>/dev/null \
  && _pass "CFG-13: /etc/hosts has influx fallback" \
  || _fail "CFG-13: /etc/hosts missing influx fallback"

grep -q 'loki.greenautarky.com' "${TARGET}/etc/hosts" 2>/dev/null \
  && _pass "CFG-14: /etc/hosts has loki fallback" \
  || _fail "CFG-14: /etc/hosts missing loki fallback"

# CFG-15/16: Service ordering
grep -q 'netbird' "${TARGET}/etc/systemd/system/telegraf.service" 2>/dev/null \
  && _pass "CFG-15: telegraf.service ordered after netbird" \
  || _fail "CFG-15: telegraf.service missing netbird ordering"

grep -q 'netbird' "$FB_SVC" 2>/dev/null \
  && _pass "CFG-16: fluent-bit.service ordered after netbird" \
  || _fail "CFG-16: fluent-bit.service missing netbird ordering"

# CFG-19/20: parsers.conf
[[ -f "${TARGET}/etc/fluent-bit/parsers.conf" ]] \
  && _pass "CFG-19: parsers.conf exists" \
  || _fail "CFG-19: parsers.conf missing"

grep -q 'homeassistant' "${TARGET}/etc/fluent-bit/parsers.conf" 2>/dev/null \
  && _pass "CFG-20: parsers.conf has homeassistant parser" \
  || _fail "CFG-20: parsers.conf missing homeassistant parser"

# CFG-22: storage buffer
grep -qE 'storage\.total_limit_size\s+300M' "${TARGET}/etc/fluent-bit/fluent-bit.conf" 2>/dev/null \
  && _pass "CFG-22: fluent-bit storage buffer >= 300M" \
  || _fail "CFG-22: fluent-bit storage buffer not 300M"

echo ""
echo "--- Environment ---"

# ENV-01: ga-env.conf
[[ -f "${TARGET}/etc/ga-env.conf" ]] \
  && _pass "ENV-01: ga-env.conf exists" \
  || _fail "ENV-01: ga-env.conf missing"

# ENV-02: GA_ENV value
GA_ENV_VAL="$(grep '^GA_ENV=' "${TARGET}/etc/ga-env.conf" 2>/dev/null | cut -d= -f2)"
case "$GA_ENV_VAL" in
  dev|prod) _pass "ENV-02: GA_ENV=$GA_ENV_VAL" ;;
  *) _fail "ENV-02: GA_ENV invalid: '$GA_ENV_VAL'" ;;
esac

# ENV-08: os-release (may be at /etc/os-release or /usr/lib/os-release)
{ grep -q 'GA_BUILD_ID' "${TARGET}/etc/os-release" 2>/dev/null || \
  grep -q 'GA_BUILD_ID' "${TARGET}/usr/lib/os-release" 2>/dev/null; } \
  && _pass "ENV-08: os-release has GA_BUILD_ID" \
  || _fail "ENV-08: os-release missing GA_BUILD_ID"

echo ""
echo "--- Services ---"

# CRASH-01: crash detection services enabled
SVC_DIR="${TARGET}/etc/systemd/system"
for svc in ga-crash-marker.service ga-boot-check.service; do
  if [[ -f "${TARGET}/usr/lib/systemd/system/${svc}" ]] || \
     [[ -L "${SVC_DIR}/sysinit.target.wants/${svc}" ]]; then
    _pass "CRASH-01: $svc installed"
  else
    _fail "CRASH-01: $svc missing"
  fi
done

# Service enable checks
for svc in netbird.service telegraf.service fluent-bit.service; do
  found=false
  for wants_dir in "${SVC_DIR}/multi-user.target.wants" "${TARGET}/usr/lib/systemd/system-preset"; do
    if [[ -L "${wants_dir}/${svc}" ]] || [[ -f "${wants_dir}/${svc}" ]]; then
      found=true; break
    fi
  done
  $found && _pass "SVC: $svc enabled" || _fail "SVC: $svc NOT enabled"
done

# DG-01: disk guard installed
[[ -f "${TARGET}/usr/sbin/ga_disk_guard" ]] || [[ -f "${TARGET}/usr/bin/ga_disk_guard" ]] \
  && _pass "DG-01: disk guard script installed" \
  || _fail "DG-01: disk guard script missing"

echo ""
echo "--- Binaries ---"

# NetBird
NB="${TARGET}/usr/bin/netbird"
[[ -x "$NB" ]] \
  && _pass "BIN: netbird binary exists" \
  || _fail "BIN: netbird binary missing"

# OS-Agent
[[ -x "${TARGET}/usr/bin/os-agent" ]] \
  && _pass "BIN: os-agent binary exists" \
  || _fail "BIN: os-agent binary missing"

echo ""
echo "--- Build artifacts ---"

# SD-01: Image file exists
IMG_XZ="$(ls "${OUT}/images/"*.img.xz 2>/dev/null | head -1)"
[[ -n "$IMG_XZ" ]] \
  && _pass "SD-01: Image file exists: $(basename "$IMG_XZ")" \
  || _fail "SD-01: No .img.xz found"

# RAUC bundle
RAUCB="$(ls "${OUT}/images/"*.raucb 2>/dev/null | head -1)"
[[ -n "$RAUCB" ]] \
  && _pass "BLD: RAUC bundle exists" \
  || _fail "BLD: No .raucb found"

# version.json
VER_JSON="${OUT}/build/hassio-1.0.0/version.json"
if [[ -f "$VER_JSON" ]]; then
  grep -q 'greenautarky' "$VER_JSON" \
    && _pass "BLD: version.json references greenautarky" \
    || _fail "BLD: version.json missing greenautarky"

  CORE_TAG="$(jq -r '.core // "unknown"' "$VER_JSON" 2>/dev/null)"
  [[ "$CORE_TAG" =~ ^2025\.[0-9]+\.[0-9]+$ ]] \
    && _pass "BLD: Core image tag is '$CORE_TAG'" \
    || _fail "BLD: Core tag is '$CORE_TAG' (expected HA version like 2025.11.3)"

  # REG: Verify all image refs use greenautarky (not upstream home-assistant or oliverc7)
  SUP_IMG="$(jq -r '.images.supervisor // "unknown"' "$VER_JSON" 2>/dev/null)"
  CORE_IMG="$(jq -r '.images.core // "unknown"' "$VER_JSON" 2>/dev/null)"
  [[ "$SUP_IMG" == *greenautarky* ]] \
    && _pass "REG-01: Supervisor image is greenautarky: $SUP_IMG" \
    || _fail "REG-01: Supervisor image is NOT greenautarky: $SUP_IMG"
  [[ "$CORE_IMG" == *greenautarky* ]] \
    && _pass "REG-02: Core image is greenautarky: $CORE_IMG" \
    || _fail "REG-02: Core image is NOT greenautarky: $CORE_IMG"

  # REG: No upstream or oliverc7 refs in version.json
  if grep -qE 'oliverc7|iHost-Open-Source' "$VER_JSON" 2>/dev/null; then
    _fail "REG-03: version.json has stale upstream refs (oliverc7 or iHost-Open-Source)"
  else
    _pass "REG-03: version.json has no stale upstream refs"
  fi
else
  _skip "BLD: version.json" "only present after full build"
fi

echo ""
echo "--- Registry consistency ---"

# REG-04: hassos-supervisor uses greenautarky image
HSUP="${TARGET}/usr/sbin/hassos-supervisor"
if [[ -f "$HSUP" ]]; then
  grep -q 'SUPERVISOR_IMAGE="ghcr.io/greenautarky/' "$HSUP" \
    && _pass "REG-04: hassos-supervisor SUPERVISOR_IMAGE is greenautarky" \
    || _fail "REG-04: hassos-supervisor SUPERVISOR_IMAGE is NOT greenautarky"

  # REG-05: fallback URL uses greenautarky
  grep -q 'greenautarky/haos-version' "$HSUP" \
    && _pass "REG-05: hassos-supervisor fallback URL is greenautarky" \
    || _fail "REG-05: hassos-supervisor fallback URL is NOT greenautarky"

  # REG-06: no oliverc7 or iHost-Open-Source references
  if grep -qE 'oliverc7|iHost-Open-Source' "$HSUP" 2>/dev/null; then
    _fail "REG-06: hassos-supervisor has stale upstream refs"
  else
    _pass "REG-06: hassos-supervisor has no stale upstream refs"
  fi
else
  _skip "REG-04/05/06: hassos-supervisor" "not found in target"
fi

# REG-07: Supervisor image tar uses greenautarky (only after full build)
SUP_TAR="$(ls "${OUT}/build/hassio-1.0.0/images/"*hassio-supervisor* 2>/dev/null | head -1)"
if [[ -n "$SUP_TAR" ]]; then
  [[ "$SUP_TAR" == *greenautarky* ]] \
    && _pass "REG-07: Supervisor tar is greenautarky: $(basename "$SUP_TAR")" \
    || _fail "REG-07: Supervisor tar is NOT greenautarky: $(basename "$SUP_TAR")"
else
  _skip "REG-07: Supervisor tar" "only present after full build"
fi

# =========================================================================
# Source file consistency (checks source tree, not build output)
# These catch misconfigurations BEFORE a full build completes
# =========================================================================
echo ""
echo "--- Source file consistency ---"

# Determine source root (container: /build, host: parent of output dir)
if [[ -d "/build/buildroot-external" ]]; then
  SRC="/build"
elif [[ -d "${OUT}/../buildroot-external" ]]; then
  SRC="$(cd "${OUT}/.." && pwd)"
else
  SRC=""
fi

if [[ -n "$SRC" ]]; then
  # SRC-01: hassio.mk VERSION_URL
  HASSIO_MK="${SRC}/buildroot-external/package/hassio/hassio.mk"
  if [[ -f "$HASSIO_MK" ]]; then
    grep -q 'greenautarky/haos-version' "$HASSIO_MK" \
      && _pass "SRC-01: hassio.mk VERSION_URL is greenautarky" \
      || _fail "SRC-01: hassio.mk VERSION_URL is NOT greenautarky"

    # SRC-02: no stale refs in hassio.mk
    if grep -qE 'oliverc7|iHost-Open-Source' "$HASSIO_MK" 2>/dev/null; then
      _fail "SRC-02: hassio.mk has stale upstream refs"
    else
      _pass "SRC-02: hassio.mk has no stale upstream refs"
    fi
  else
    _skip "SRC-01/02" "hassio.mk not found"
  fi

  # SRC-03: dind-import-containers.sh tags greenautarky
  DIND="${SRC}/buildroot-external/package/hassio/dind-import-containers.sh"
  if [[ -f "$DIND" ]]; then
    grep -q 'ghcr.io/greenautarky.*hassio-supervisor' "$DIND" \
      && _pass "SRC-03: dind-import tags supervisor as greenautarky" \
      || _fail "SRC-03: dind-import does NOT tag supervisor as greenautarky"

    # SRC-04: no stale refs in dind-import
    if grep -qE 'oliverc7|iHost-Open-Source' "$DIND" 2>/dev/null; then
      _fail "SRC-04: dind-import has stale upstream refs"
    else
      _pass "SRC-04: dind-import has no stale upstream refs"
    fi
  else
    _skip "SRC-03/04" "dind-import-containers.sh not found"
  fi

  # SRC-05: hassos-supervisor source matches dind-import tag prefix
  HSUP_SRC="${SRC}/buildroot-external/rootfs-overlay/usr/sbin/hassos-supervisor"
  if [[ -f "$HSUP_SRC" ]] && [[ -f "$DIND" ]]; then
    # Extract the image prefix from both files and compare
    HSUP_PREFIX="$(grep 'SUPERVISOR_IMAGE=' "$HSUP_SRC" | head -1 | sed 's/.*"\(.*\)\/.*/\1/')"
    DIND_PREFIX="$(grep 'docker tag.*hassio-supervisor' "$DIND" | head -1 | sed 's/.*"\(.*\)\/.*/\1/')"
    if [[ "$HSUP_PREFIX" == "$DIND_PREFIX" ]] && [[ -n "$HSUP_PREFIX" ]]; then
      _pass "SRC-05: hassos-supervisor and dind-import use same prefix: $HSUP_PREFIX"
    else
      _fail "SRC-05: prefix mismatch: hassos-supervisor='$HSUP_PREFIX' vs dind-import='$DIND_PREFIX'"
    fi
  else
    _skip "SRC-05" "source files not found"
  fi

  # SRC-06: updater.json has real HA version (not 'latest')
  if [[ -f "$DIND" ]]; then
    HA_VER_IN_DIND="$(grep 'homeassistant' "$DIND" | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -1)"
    if [[ -n "$HA_VER_IN_DIND" ]]; then
      _pass "SRC-06: updater.json uses real HA version: $HA_VER_IN_DIND"
    elif grep -q '"latest"' "$DIND" 2>/dev/null; then
      _fail "SRC-06: updater.json uses 'latest' (HA rejects this)"
    else
      _skip "SRC-06" "could not parse HA version from dind-import"
    fi
  fi

  # SRC-07: ga_build.sh exports GA_BUILD_TIMESTAMP and GA_ENV
  GA_BUILD="${SRC}/scripts/ga_build.sh"
  if [[ -f "$GA_BUILD" ]]; then
    grep -q 'export GA_BUILD_TIMESTAMP' "$GA_BUILD" \
      && _pass "SRC-07: ga_build.sh exports GA_BUILD_TIMESTAMP" \
      || _fail "SRC-07: ga_build.sh does NOT export GA_BUILD_TIMESTAMP"
  else
    _skip "SRC-07" "ga_build.sh not found"
  fi

  # SRC-08: post-build.sh stamps GA_BUILD_ID into os-release
  POST_BUILD="${SRC}/buildroot-external/scripts/post-build.sh"
  if [[ -f "$POST_BUILD" ]]; then
    grep -q 'GA_BUILD_ID' "$POST_BUILD" \
      && _pass "SRC-08: post-build.sh stamps GA_BUILD_ID" \
      || _fail "SRC-08: post-build.sh does NOT stamp GA_BUILD_ID"
  else
    _skip "SRC-08" "post-build.sh not found"
  fi

  # SRC-09: Global stale reference scan across all functional source
  STALE_COUNT=0
  for dir in "${SRC}/buildroot-external/package" "${SRC}/buildroot-external/rootfs-overlay" "${SRC}/scripts"; do
    [[ -d "$dir" ]] || continue
    hits=$(grep -rlE 'oliverc7|iHost-Open-Source-Project' "$dir" 2>/dev/null | wc -l)
    STALE_COUNT=$((STALE_COUNT + hits))
  done
  if [[ "$STALE_COUNT" -eq 0 ]]; then
    _pass "SRC-09: No stale refs (oliverc7/iHost-Open-Source) in functional source"
  else
    _fail "SRC-09: Found $STALE_COUNT file(s) with stale upstream refs in functional source"
  fi
else
  _skip "SRC-01..09" "source tree not found (expected /build or parent of output)"
fi

# =========================================================================
# Summary
# =========================================================================
echo ""
total=$((pass + fail + skip))
echo "=== Build tests: ${pass} passed, ${fail} failed, ${skip} skipped (${total} total) ==="
echo "{\"suite\":\"build\",\"pass\":${pass},\"fail\":${fail},\"skip\":${skip}}"
echo ""

exit $fail
