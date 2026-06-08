#!/usr/bin/env bash
# qemu-ci.sh — one-shot orchestrator for the qemu CI lane.
#
# Three responsibilities:
#   1. Build the qemu OS image (if --build is yes/auto and no image present).
#   2. Boot it under qemu-system-x86_64 via tests/qemu-ci/runner.py.
#   3. Surface results: exit 0 if every requested suite passes, non-zero
#      otherwise. Serial log + JSON summary land in $WORKDIR.
#
# Designed to be callable from:
#   - a developer laptop (`./scripts/qemu-ci.sh`)
#   - the GH Actions workflow (.github/workflows/qemu-ci.yml)
#   - the `make qemu-test` target
#
# Does NOT touch the iHost build path. Both lanes coexist; ga_build.sh
# stays the canonical iHost builder.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# ---- defaults ----
WORKDIR="${WORKDIR:-/tmp/qemu-ci}"
IMAGES_DIR="${IMAGES_DIR:-${REPO_ROOT}/ga_output_qemu/images}"
BUILD="${BUILD:-auto}"      # auto | yes | no
SUITES="${SUITES:-environment crash_detection boot_timing disk_guard supervisor_health}"
ACCEL="${ACCEL:-auto}"      # auto | kvm | tcg
MEM_MB="${MEM_MB:-2048}"
CPUS="${CPUS:-2}"
IMAGE_OVERRIDE=""
KEEP_QCOW2="${KEEP_QCOW2:-0}"

usage() {
  cat <<EOF
qemu-ci.sh — build + boot + test a haos_qemu image

Usage: $0 [options]

  --build {auto|yes|no}    Build the qemu image first (default: auto — build
                           only if no haos_qemu-*.qcow2.xz is found)
  --image PATH             Use a specific qcow2.xz instead of auto-detecting
  --suites "a b c"        Suites to run inside the VM (default: emu category
                           = environment crash_detection boot_timing
                             disk_guard supervisor_health)
  --accel {auto|kvm|tcg}  qemu accelerator (default: auto)
  --mem MB                 VM RAM (default: 2048)
  --cpus N                 vCPUs (default: 2)
  --workdir PATH           Scratch / artifacts dir (default: /tmp/qemu-ci)
  --keep-qcow2             Don't delete the working qcow2 after the run
  -h, --help               Show this help

Environment overrides: WORKDIR, IMAGES_DIR, BUILD, SUITES, ACCEL, MEM_MB,
CPUS, KEEP_QCOW2.

Exit codes:
  0  all suites pass
  1  one or more in-VM test failures
  2  prerequisite missing (qemu, pexpect, python3, etc.)
  3  VM never booted (kernel panic, timeout)
  4  test share didn't mount inside the VM
  5  build failed
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)      BUILD="$2"; shift 2 ;;
    --image)      IMAGE_OVERRIDE="$2"; shift 2 ;;
    --suites)     SUITES="$2"; shift 2 ;;
    --accel)      ACCEL="$2"; shift 2 ;;
    --mem)        MEM_MB="$2"; shift 2 ;;
    --cpus)       CPUS="$2"; shift 2 ;;
    --workdir)    WORKDIR="$2"; shift 2 ;;
    --keep-qcow2) KEEP_QCOW2=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

mkdir -p "$WORKDIR"

# ---- prerequisite checks ----
need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "FATAL: $1 missing from PATH" >&2
    echo "  Install with: $2" >&2
    exit 2
  }
}
need qemu-system-x86_64 "apt-get install qemu-system-x86"
need qemu-img            "apt-get install qemu-utils"
need xz                  "apt-get install xz-utils"
need python3             "apt-get install python3"

if ! python3 -c "import pexpect" >/dev/null 2>&1; then
  echo "FATAL: python3-pexpect not available" >&2
  echo "  Install with: apt-get install python3-pexpect  OR  pip3 install pexpect" >&2
  exit 2
fi

if [[ ! -f /usr/share/ovmf/OVMF.fd ]]; then
  echo "FATAL: OVMF firmware missing (/usr/share/ovmf/OVMF.fd)" >&2
  echo "  Install with: apt-get install ovmf" >&2
  exit 2
fi

# ---- resolve accel ----
if [[ "$ACCEL" == "auto" ]]; then
  if [[ -e /dev/kvm ]] && [[ -r /dev/kvm ]] && [[ -w /dev/kvm ]]; then
    ACCEL=kvm
  else
    ACCEL=tcg
    echo "[qemu-ci] /dev/kvm not usable — falling back to tcg (slower)" >&2
  fi
fi

# ---- image resolution ----
resolve_image() {
  if [[ -n "$IMAGE_OVERRIDE" ]]; then
    printf '%s\n' "$IMAGE_OVERRIDE"
    return
  fi
  # newest haos_qemu-*.qcow2.xz (or the renamed bos_qemu-*) under IMAGES_DIR
  find "$IMAGES_DIR" -maxdepth 1 \
    \( -name 'haos_qemu-*.qcow2.xz' -o -name 'bos_qemu-*.qcow2.xz' \) \
    2>/dev/null \
    | xargs -r ls -1t 2>/dev/null | head -1 || true
}

IMAGE="$(resolve_image)"

case "$BUILD" in
  yes)
    NEED_BUILD=1 ;;
  no)
    NEED_BUILD=0
    if [[ -z "$IMAGE" ]]; then
      echo "FATAL: --build=no but no qemu image found in $IMAGES_DIR" >&2
      exit 5
    fi ;;
  auto)
    if [[ -z "$IMAGE" ]]; then
      NEED_BUILD=1
      echo "[qemu-ci] no qemu image found; will build (--build=auto)"
    else
      NEED_BUILD=0
      echo "[qemu-ci] using existing image: $IMAGE"
    fi ;;
  *)
    echo "FATAL: --build must be auto|yes|no, got '$BUILD'" >&2
    exit 2 ;;
esac

# ---- build (parallel output dir so we never touch the iHost build cache) ----
if [[ "$NEED_BUILD" == "1" ]]; then
  echo "[qemu-ci] building qemu image ..."
  # ga_build.sh is hard-coded to the iHost defconfig; we drive Buildroot
  # directly via the top-level Makefile's catch-all target. The OUT dir is
  # `ga_output_qemu` so it never overlaps with the iHost `ga_output`.
  #
  # CI path (hassos:local image present + docker): build inside the
  # container so the host doesn't need the full toolchain.
  # Laptop path (no docker): assume the host has build-essential etc. and
  # call make directly. Both end up in the same OUT dir.
  if command -v docker >/dev/null 2>&1 \
       && docker image inspect hassos:local >/dev/null 2>&1; then
    docker run --rm --privileged \
      -v "$REPO_ROOT:/build" \
      -v "${HOME}/hassos-cache:/cache" \
      -e BUILDER_UID="$(id -u)" -e BUILDER_GID="$(id -g)" \
      hassos:local \
      bash -c 'cd /build && \
        make O=ga_output_qemu \
          BR2_EXTERNAL=/build/buildroot-ihost:/build/buildroot-external \
          ga_qemu_defconfig && \
        make O=ga_output_qemu \
          BR2_EXTERNAL=/build/buildroot-ihost:/build/buildroot-external \
          -j$(nproc)'
  else
    (
      cd "$REPO_ROOT"
      make O=ga_output_qemu \
        BR2_EXTERNAL="$REPO_ROOT/buildroot-ihost:$REPO_ROOT/buildroot-external" \
        ga_qemu_defconfig
      make O=ga_output_qemu \
        BR2_EXTERNAL="$REPO_ROOT/buildroot-ihost:$REPO_ROOT/buildroot-external" \
        -j"$(nproc)"
    )
  fi
  IMAGE="$(resolve_image)"
  if [[ -z "$IMAGE" ]]; then
    echo "FATAL: build completed but no haos_qemu*.qcow2.xz produced in $IMAGES_DIR" >&2
    exit 5
  fi
  echo "[qemu-ci] built: $IMAGE"
fi

# ---- run ----
SERIAL_LOG="${WORKDIR}/qemu-serial.log"
RESULTS_JSON="${WORKDIR}/qemu-results.json"

echo "[qemu-ci] starting VM (accel=$ACCEL mem=${MEM_MB}M cpus=${CPUS})"
echo "[qemu-ci] serial log:  $SERIAL_LOG"
echo "[qemu-ci] results:     $RESULTS_JSON"

export QEMU_CI_KEEP_QCOW2="$KEEP_QCOW2"

set +e
python3 "${REPO_ROOT}/tests/qemu-ci/runner.py" \
  --image "$IMAGE" \
  --workdir "$WORKDIR" \
  --mem "$MEM_MB" \
  --cpus "$CPUS" \
  --accel "$ACCEL" \
  --suites "$SUITES" \
  --serial-log "$SERIAL_LOG" \
  --results "$RESULTS_JSON"
rc=$?
set -e

# ---- post-run summary ----
if [[ -f "$RESULTS_JSON" ]]; then
  echo ""
  echo "=== qemu-ci summary ==="
  python3 - "$RESULTS_JSON" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
for k in ('booted', 'multi_user_reached', 'supervisor_ready', 'suites_run',
         'pass_count', 'fail_count', 'skip_count', 'elapsed_s', 'fail_reason'):
    print(f'  {k:22} {r.get(k)}')
PY
fi

exit $rc
