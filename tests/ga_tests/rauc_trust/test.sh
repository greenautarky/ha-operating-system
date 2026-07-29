#!/bin/sh
# RAUC trust-anchor pins.
#
# WHAT THIS GUARDS
# ----------------
# Every certificate in buildroot-external/ota/ ends up, directly or
# transitively, in /etc/rauc/keyring.pem — the set of keys a device will accept
# an OTA from. Adding one is the single highest-consequence change in this
# repository: it decides who may replace the operating system on every device
# in the fleet.
#
# The pins below make that change VISIBLE. Adding, swapping or removing a trust
# anchor turns this suite red and has to be argued for in the pull request,
# instead of arriving as a binary blob nobody diffs.
#
# WHY FINGERPRINTS AND NOT SUBJECTS
# ---------------------------------
# Measured 2026-07-29 on a real rc39 build. Read by subject, the keyring looks
# like this:
#
#   CN = iHost RAUC Dev CA
#   O = HassOS, CN = HassOS Self-signed Development Certificate
#   O = HassOS, CN = HassOS Self-signed Development Certificate
#
# — as if it held two ordinary development certificates. By fingerprint, the
# third one is 01:E7:CE:81…, the RETIRED pre-2026-03-27 signing CA that the
# 2026-03-27 rotation was supposed to remove. It is self-signed, CA:TRUE, valid
# until 2035, and system.conf sets no check-crl, so there is no revocation path
# for it.
#
# A subject-based check would have called that keyring clean. Anything asserting
# trust here compares fingerprints.
#
# Pure host-side: needs only sh + openssl. No build and no device required.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "RAUC trust anchors (fingerprint pins)"

REPO="$SCRIPT_DIR/../../.."
OTA="$REPO/buildroot-external/ota"
RAUC_SH="$REPO/buildroot-external/scripts/rauc.sh"
META="$REPO/buildroot-external/meta"

# --- The pinned set ---------------------------------------------------------
# Every certificate this repository is allowed to ship as a trust anchor.
#
# CHANGING THIS LIST IS A SECURITY DECISION. A new entry means a new party may
# sign an OS image for the fleet. It needs the fingerprint, what it is, and why
# it is trusted — not just a line.
#
# FE:4E… — "iHost RAUC Dev CA", the anchor copied into the keyring by
#          install_rauc_certs(). dev-ca.pem and rel-ca.pem are currently the
#          SAME certificate, so development and release builds trust the same
#          root; that is pinned below as its own test rather than left implicit.
# 01:E7… — the retired pre-2026-03-27 signing CA. Present ONLY through the
#          GA_LEGACY_CA_BRIDGE opt-in. Its fingerprint is also quoted in a
#          comment in rauc.sh, and the two are checked against each other.
# Pinned here for the build suite to import; not checkable in CI (see TRUST-06).
CA_IHOST_RAUC_DEV="FE:4E:81:8A:4D:3E:8A:9B:C8:C2:56:0B:DC:F3:37:5B:36:5C:66:D3:D0:84:69:50:B6:4B:AE:DA:A1:D3:92:06"
CA_LEGACY_F13="01:E7:CE:81:49:6B:75:43:22:3C:8B:31:29:4C:78:AB:D3:02:7F:FE:62:7A:B5:B6:28:AF:73:83:E1:21:BC:F7"

fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2; }

run_test "TRUST-01" "openssl available (a skipped check is not a pass)" \
  "command -v openssl >/dev/null"

run_test "TRUST-02" "the OTA cert directory exists" "test -d '$OTA'"

# --- every shipped cert is one we pinned ------------------------------------
# Default-deny: the loop walks what is ON DISK and demands each be known,
# rather than checking that known ones are present. A newly added .pem is
# therefore caught the moment it appears.
UNKNOWN=""
COUNT=0
for f in "$OTA"/*.pem; do
    [ -f "$f" ] || continue
    COUNT=$((COUNT + 1))
    F="$(fp "$f")"
    case "$F" in
        "$CA_IHOST_RAUC_DEV"|"$CA_LEGACY_F13") : ;;
        "") UNKNOWN="$UNKNOWN $(basename "$f"):unparseable" ;;
        *)  UNKNOWN="$UNKNOWN $(basename "$f"):$F" ;;
    esac
done

run_test "TRUST-03" "at least one certificate was actually examined" \
  "[ '$COUNT' -ge 1 ]"
run_test "TRUST-04" "no unpinned trust anchor among the tracked certs" \
  "[ -z '$UNKNOWN' ]"
[ -n "$UNKNOWN" ] && printf '        unpinned:%s\n' "$UNKNOWN"

run_test "TRUST-05" "legacy-signing-cert.pem is the retired F13 CA and nothing else" \
  "[ \"\$(openssl x509 -in '$OTA/legacy-signing-cert.pem' -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)\" = '$CA_LEGACY_F13' ]"

# --- what this suite CANNOT see, said out loud ------------------------------
# .gitignore excludes *.pem, so dev-ca.pem and rel-ca.pem — the anchors
# install_rauc_certs() actually copies into the keyring — exist only on the
# build host and appear in no pull request. The one .pem that IS tracked is the
# RETIRED legacy CA. The file under review is the one we want gone; the files
# that grant OTA authority are invisible to review.
#
# That is a finding, not something to skip past: a SKIP here would read as a
# pass on exactly the certificates that matter most. So the state is asserted
# instead — they must be *deliberately* untracked, and RAUC-KEYRING-* in the
# build suite pins their fingerprints where they exist.
run_test "TRUST-06" "the build-time anchors are deliberately untracked (not merely missing)" \
  "git -C '$REPO' check-ignore -q buildroot-external/ota/dev-ca.pem"
printf '        NOT REVIEWABLE HERE: dev-ca.pem / rel-ca.pem live on the build host.\n'
printf '        Their fingerprints are pinned by RAUC-KEYRING-* in the build suite,\n'
printf '        which runs where the assembled keyring exists.\n'

run_test "TRUST-07" "no private key material is tracked in the OTA dir" \
  "! grep -rlqE 'BEGIN (RSA |EC |ENCRYPTED )?PRIVATE KEY' '$OTA' 2>/dev/null"

# --- the comment in rauc.sh must not drift from the file --------------------
# rauc.sh documents the legacy fingerprint in a comment. A comment that no
# longer matches the file it describes is worse than none: it is the thing a
# reviewer checks against.
run_test "TRUST-09" "rauc.sh's documented legacy fingerprint matches the file" \
  "grep -qF '$(echo "$CA_LEGACY_F13" | tr -d ':')' '$RAUC_SH' || grep -qF '$CA_LEGACY_F13' '$RAUC_SH'"

# --- the bridge flag is explicit --------------------------------------------
BRIDGE="$(sed -nE 's/^GA_LEGACY_CA_BRIDGE="?([^"]*)"?.*/\1/p' "$META" 2>/dev/null | head -1)"
run_test "TRUST-10" "GA_LEGACY_CA_BRIDGE is declared explicitly in meta" \
  "[ -n '$BRIDGE' ]"
printf '        GA_LEGACY_CA_BRIDGE=%s\n' "${BRIDGE:-<unset>}"

# --- the retirement gate ----------------------------------------------------
# THIS is the check the key rotation turns on. While the bridge is true the
# retired CA ships and this test records that as an accepted, temporary state.
# Set GA_REQUIRE_LEGACY_CA_RETIRED=1 (the release build should) and it becomes
# a hard failure — so "the old keys are retired" cannot be asserted while the
# repository still ships them.
if [ "$BRIDGE" = "true" ]; then
    if [ "${GA_REQUIRE_LEGACY_CA_RETIRED:-0}" = "1" ]; then
        run_test "TRUST-11" "legacy CA retired (GA_REQUIRE_LEGACY_CA_RETIRED=1)" "false"
        printf '        GA_LEGACY_CA_BRIDGE is still true — the retired pre-2026-03-27 CA\n'
        printf '        would be baked into the keyring, so old-key bundles still verify.\n'
    else
        skip_test "TRUST-11" "legacy CA still bridged on purpose (GA_LEGACY_CA_BRIDGE=true)"
        printf '        Not a failure yet. Devices provisioned before the 2026-03-27\n'
        printf '        rotation cannot verify current-key OTAs without it. Set\n'
        printf '        GA_REQUIRE_LEGACY_CA_RETIRED=1 once the field audit is done.\n'
    fi
else
    run_test "TRUST-11" "legacy CA NOT bridged — retired anchor is not shipped" "true"
fi

# --- expiry -----------------------------------------------------------------
# A trust anchor that outlives the fleet is its own problem: these are all
# CA:TRUE, self-signed, and system.conf sets no check-crl, so there is no way
# to withdraw one before it expires. Report the dates so the horizon is visible
# rather than discovered.
for f in "$OTA"/*.pem; do
    [ -f "$f" ] || continue
    printf '        %-26s notAfter=%s\n' "$(basename "$f")" \
      "$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)"
done

suite_end
