#!/bin/sh
# OTA trust — a bundle signed with a key the device does not trust must be
# REJECTED by `rauc install`, with a signature error (ADR-0027 D9).
#
# DEVICE-ONLY, ON DEMAND. Not part of any category run: it needs a throwaway-
# signed bundle staged on the device first. Produce it on a host with
#
#   tests/ga_tests/ota_trust/make-throwaway-bundle.sh <outdir>
#
# copy <outdir>/throwaway.raucb and <outdir>/throwaway-cert.pem to the device
# (NOT /tmp for anything large — the bundle is a few KB, so /tmp is fine here),
# then on the device:
#
#   THROWAWAY_RAUCB=/tmp/throwaway.raucb THROWAWAY_CERT=/tmp/throwaway-cert.pem \
#     sh /tmp/ga_tests/ota_trust/test.sh
#
# WHY THIS EXISTS
#   Every KEYRING-* check inspects the BUILD: what is in the keyring file. None
#   of them asks the device the one question that matters — will it refuse an
#   update signed by somebody else? A keyring can be exactly right and the
#   answer still be wrong (a system.conf that points elsewhere, a RAUC built
#   without signature checks, a keyring path the image does not ship). This asks
#   the running device, through the real install path.
#
# SAFETY — the throwaway bundle is built so that being wrong costs nothing:
#   * `rauc info` (verification only, writes nothing) is asked FIRST. If the
#     device ACCEPTS the signature there, the test fails and `rauc install` is
#     never run.
#   * The bundle's single image targets a slot class that does not exist
#     (`ga-trust-probe`), so even an install that got past the signature could
#     not write to a real slot.
#   * `rauc status` before and after must be identical.
#
#   KEYRING-NEG-01  positive control: the bundle verifies against ITS OWN
#                   cert — it is a well-formed bundle, so a rejection below is
#                   about trust, not about a broken file
#   KEYRING-NEG-02  `rauc info` with the device keyring rejects it, and says
#                   signature (not compatible / format / I/O)
#   KEYRING-NEG-03  `rauc install` rejects it, and says signature
#   KEYRING-NEG-04  the slot status is unchanged by the attempt
#
# Status 2026-09-24: written and fixture-tested (selftest.sh, shimmed rauc);
# NOT yet run on hardware. See the landing checklist in the D9 report.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "OTA trust (throwaway-key bundle must be rejected)"

RAUCB="${THROWAWAY_RAUCB:-}"
CERT="${THROWAWAY_CERT:-}"
# The signature-error shapes RAUC reports (signature.c / bundle.c), plus the
# OpenSSL chain reasons it embeds. Deliberately NOT matching "compatible",
# "format", "No such file" — a rejection for those reasons proves nothing.
SIG_RE='signature verification failed|failed to verify (bundle )?signature|verifying signature failed|unable to get local issuer certificate|self[- ]signed certificate|certificate verify failed'

W="$(mktemp -d 2>/dev/null || echo /tmp/ota_trust_$$)"
trap 'rm -rf "$W"' EXIT INT TERM

if ! command -v rauc >/dev/null 2>&1; then
  run_test "KEYRING-NEG-00" "rauc is available on this device" "false"
  suite_end; exit 1
fi
if [ -z "$RAUCB" ] || [ ! -f "$RAUCB" ] || [ -z "$CERT" ] || [ ! -f "$CERT" ]; then
  # On demand means the inputs are part of the request. Missing inputs are a
  # FAILED run, never a skip: a skip here would read like "trust is fine".
  run_test "KEYRING-NEG-00" "throwaway bundle + cert staged (THROWAWAY_RAUCB='${RAUCB}' THROWAWAY_CERT='${CERT}')" "false"
  echo "        -> build them with tests/ga_tests/ota_trust/make-throwaway-bundle.sh and copy them over"
  suite_end; exit 1
fi
run_test "KEYRING-NEG-00" "throwaway bundle + cert staged" "true"

rauc status --output-format=shell > "$W/status.before" 2>&1

# KEYRING-NEG-01 — positive control. Without it, a truncated copy of the bundle
# would be "rejected" too, and the test would pass for the wrong reason.
if rauc info --keyring="$CERT" "$RAUCB" > "$W/ctl.out" 2>&1; then
  run_test "KEYRING-NEG-01" "positive control: bundle verifies against its own throwaway cert" "true"
else
  run_test "KEYRING-NEG-01" "positive control: bundle verifies against its own throwaway cert" "false"
  sed 's/^/        /' "$W/ctl.out" | head -4
  echo "        -> the bundle itself is broken; no verdict about trust is possible"
  suite_end; exit 1
fi

# KEYRING-NEG-02 — verification only, against the keyring the device runs.
if rauc info "$RAUCB" > "$W/info.out" 2>&1; then
  run_test "KEYRING-NEG-02" "device keyring REJECTS the throwaway signature (rauc info)" "false"
  echo "        -> ACCEPTED. This device trusts a key it has never seen. NOT running rauc install."
  sed 's/^/        /' "$W/info.out" | head -4
  suite_end; exit 1
fi
if grep -qiE "$SIG_RE" "$W/info.out"; then
  run_test "KEYRING-NEG-02" "device keyring REJECTS the throwaway signature (rauc info)" "true"
else
  run_test "KEYRING-NEG-02" "device keyring rejects it — but NOT with a signature error" "false"
  sed 's/^/        /' "$W/info.out" | head -4
fi

# KEYRING-NEG-03 — the real install path.
if rauc install "$RAUCB" > "$W/install.out" 2>&1; then
  run_test "KEYRING-NEG-03" "rauc install REJECTS the throwaway-signed bundle" "false"
  echo "        -> rauc install EXITED 0"
  sed 's/^/        /' "$W/install.out" | tail -4
elif grep -qiE "$SIG_RE" "$W/install.out"; then
  run_test "KEYRING-NEG-03" "rauc install REJECTS the throwaway-signed bundle with a signature error" "true"
  echo "        -> $(grep -iE "$SIG_RE" "$W/install.out" | head -1)"
else
  run_test "KEYRING-NEG-03" "rauc install rejects it — but NOT with a signature error" "false"
  sed 's/^/        /' "$W/install.out" | tail -4
fi

# KEYRING-NEG-04 — nothing moved.
rauc status --output-format=shell > "$W/status.after" 2>&1
run_test "KEYRING-NEG-04" "slot status unchanged by the rejected install" \
  "cmp -s '$W/status.before' '$W/status.after'"

suite_end
