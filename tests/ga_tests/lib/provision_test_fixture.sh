#!/bin/sh
# tests/ga_tests/lib/provision_test_fixture.sh — synthetic provisioner.
#
# Lays the per-device files that the REAL ga-flasher-py pipeline would
# write at rack-time (= stages 60..72), so an on-device E2E test can run
# against a freshly flashed device with NO MANUAL SETUP between the
# `dd` of the OS image and the test invocation.
#
# Compared to the full 46-stage provisioner, this fixture intentionally
# does LESS — only the files that downstream components actually read:
#
#   /share/ga/ghcr-creds.json            — ga_manager converge step 0.5
#   /share/ga-fleet-bundle.yaml          — bundle_expectation health check
#   /share/ga-device-id                  — telegraf measurement tag
#   /mnt/data/ga-device-label            — fluent-bit device_label tag
#   /share/.ga_os                        — converge auto-enqueue trigger
#   /share/ga-custom-components/<name>/  — converge step 2 staging area
#   /mnt/data/ghcr-creds.json            — ga-bootstrap GHCR_CREDS_FILE override
#                                          (the script's /etc/ default is RO on HAOS)
#
# Designed to be IDEMPOTENT: re-running is a no-op when files are already
# present + correct. Each file is written once per fixture invocation; no
# attempt is made to MERGE with operator-customised values.
#
# Inputs (env, all optional):
#   GHCR_PAT                   — fleet-wide PAT for ghcr.io pulls (required for
#                                ga_manager addon install on first boot)
#   GHCR_USER                  — username (default Thomastaube)
#   DEVICE_ID                  — KIB-SON-id-style label (default KIB-SON-TEST)
#   BUNDLE_VERSION             — ga-fleet-bundle.yaml `bundle:` value (default v1.2)
#
# Outputs: prints what it wrote / what was already present. Exits 0 on
# success, non-zero on a hard failure (missing PAT for first-boot, etc).
#
# Limitations:
#   - Does NOT drive ga-flasher-py's real stages — see Option B in
#     memory/todo_e2e_provisioning_chain_test.md when we want to
#     exercise the provisioner code path itself.
#   - Does NOT enrol Tailscale / NetBird / wifi — assumes the device
#     already has network connectivity (i.e. ran through ga-flasher
#     stages 1-50 OR was hand-configured).

set -eu

GHCR_PAT="${GHCR_PAT:-}"
GHCR_USER="${GHCR_USER:-Thomastaube}"
DEVICE_ID="${DEVICE_ID:-KIB-SON-TEST}"
BUNDLE_VERSION="${BUNDLE_VERSION:-v1.2}"

SHARE_DIR="/mnt/data/supervisor/share"
MNT_DATA="/mnt/data"
ROOTFS_COMPONENTS="/usr/share/ga/custom_components"
STAGED_COMPONENTS="${SHARE_DIR}/ga-custom-components"

log() { printf '[provision-fixture] %s\n' "$*"; }
fail() { log "ERROR: $1"; exit "${2:-1}"; }

[ "$(id -u)" -eq 0 ] || fail "must run as root (= on-device)" 64

# 1. GHCR creds. The REAL provisioner writes /share/ga/ghcr-creds.json
# (= ga_manager converge step 0.5 reads it) AND /etc/ga/ghcr-creds.json
# (= ga-bootstrap script reads it). Since /etc is RO on HAOS, we write
# the secondary creds file under /mnt/data and rely on a runtime override
# (BG_BOOTSTRAP environment) to point ga-bootstrap at the writable path.
mkdir -p "${SHARE_DIR}/ga"
chmod 0700 "${SHARE_DIR}/ga"
SHARE_CREDS="${SHARE_DIR}/ga/ghcr-creds.json"
MNT_CREDS="${MNT_DATA}/ghcr-creds.json"

if [ -f "${SHARE_CREDS}" ] && [ -f "${MNT_CREDS}" ]; then
  log "GHCR creds files already present — skip"
else
  if [ -z "${GHCR_PAT}" ]; then
    fail "GHCR_PAT not set + creds files missing — first-boot addon install would fail" 2
  fi
  CREDS_JSON="{\"ghcr.io\":{\"username\":\"${GHCR_USER}\",\"password\":\"${GHCR_PAT}\"}}"
  printf '%s' "${CREDS_JSON}" > "${SHARE_CREDS}"
  chmod 0600 "${SHARE_CREDS}"
  printf '%s' "${CREDS_JSON}" > "${MNT_CREDS}"
  chmod 0600 "${MNT_CREDS}"
  log "wrote ${SHARE_CREDS} + ${MNT_CREDS}"
fi

# 2. ga-fleet-bundle.yaml — minimal stub. ga_manager's bundle_expectation
# check needs only the `bundle:` line; other fields are optional and
# default to "anything".
BUNDLE_FILE="${SHARE_DIR}/ga-fleet-bundle.yaml"
if [ -f "${BUNDLE_FILE}" ]; then
  log "${BUNDLE_FILE} already present — skip"
else
  cat > "${BUNDLE_FILE}" <<EOF
# Written by tests/ga_tests/lib/provision_test_fixture.sh. Stub — does
# not assert anything beyond the bundle marker so the drift health
# check can run without spurious WARNINGs.
bundle: "${BUNDLE_VERSION}"
EOF
  chmod 0644 "${BUNDLE_FILE}"
  log "wrote ${BUNDLE_FILE} (bundle=${BUNDLE_VERSION})"
fi

# 3. ga-device-id + ga-device-label
DEVICE_ID_FILE="${SHARE_DIR}/ga-device-id"
DEVICE_LABEL_FILE="${MNT_DATA}/ga-device-label"
[ -f "${DEVICE_ID_FILE}" ] || {
  printf '%s' "${DEVICE_ID}" > "${DEVICE_ID_FILE}"
  chmod 0644 "${DEVICE_ID_FILE}"
  log "wrote ${DEVICE_ID_FILE}"
}
[ -f "${DEVICE_LABEL_FILE}" ] || {
  printf '%s' "${DEVICE_ID}" > "${DEVICE_LABEL_FILE}"
  chmod 0644 "${DEVICE_LABEL_FILE}"
  log "wrote ${DEVICE_LABEL_FILE}"
}

# 4. /share/.ga_os — converge auto-enqueue trigger. The real
# ga-bootstrap-disk service writes this to mark the device as
# V1.2-clean ready.
OS_MARKER="${SHARE_DIR}/.ga_os"
[ -f "${OS_MARKER}" ] || {
  printf 'v1.2-clean\n' > "${OS_MARKER}"
  chmod 0644 "${OS_MARKER}"
  log "wrote ${OS_MARKER}"
}

# 5. Stage custom_components from rootfs to /share/ga-custom-components/
# where ga_manager converge step 2 expects them. This step normally
# happens automatically via the rootfs-overlay mounts; we mirror it
# here so the test doesn't depend on the OS-side stage running first.
if [ -d "${ROOTFS_COMPONENTS}" ]; then
  mkdir -p "${STAGED_COMPONENTS}"
  for comp_dir in "${ROOTFS_COMPONENTS}"/*; do
    [ -d "${comp_dir}" ] || continue
    comp_name=$(basename "${comp_dir}")
    if [ -d "${STAGED_COMPONENTS}/${comp_name}" ]; then
      log "${STAGED_COMPONENTS}/${comp_name} already staged — skip"
    else
      cp -r "${comp_dir}" "${STAGED_COMPONENTS}/${comp_name}"
      log "staged ${comp_name} into ${STAGED_COMPONENTS}/"
    fi
  done
else
  log "WARN: ${ROOTFS_COMPONENTS} not present — custom_components not staged"
fi

# 6. /etc/ga-bootstrap.conf — would override GHCR_CREDS_FILE, but /etc is
# RO on HAOS. We can't write it directly. The override has to come via
# the .service file's Environment= directive, which is also RO without
# a drop-in under /mnt/overlay/etc/systemd/.... For the fixture path
# we just print a friendly hint.
if [ ! -f /etc/ga/ghcr-creds.json ]; then
  log "NOTE: /etc/ga/ghcr-creds.json is RO and absent. The OS image MUST"
  log "      bake it at build time OR ga-bootstrap.service needs a drop-in"
  log "      Environment=GHCR_CREDS_FILE=${MNT_CREDS}. See memory:"
  log "      todo_ga_bootstrap_creds_path. For now ${MNT_CREDS} is in place;"
  log "      ga-bootstrap will fail Step 3 unless an operator invokes it"
  log "      manually with GHCR_CREDS_FILE=${MNT_CREDS}."
fi

log "fixture complete. files written:"
ls -la "${SHARE_CREDS}" "${MNT_CREDS}" "${BUNDLE_FILE}" "${DEVICE_ID_FILE}" \
       "${DEVICE_LABEL_FILE}" "${OS_MARKER}" 2>&1 | awk '/^-/ {print "  " $9}'
ls -la "${STAGED_COMPONENTS}" 2>&1 | awk '/^d/ && $9 != "." && $9 != ".." {print "  " "${STAGED_COMPONENTS}/" $9}'
