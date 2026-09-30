#!/bin/bash
# =============================================================================
# 87-ssh-cert-plane.sh — put a BOSv1.4.0+ image on the certificate plane
# (ADR-0019 step 2). Does NOTHING on an image below the cut.
# =============================================================================
# Usage:
#   87-ssh-cert-plane.sh <TARGET_DIR>          post-build hook (buildroot)
#   87-ssh-cert-plane.sh --check <GA_RELEASE>  preflight (scripts/ga_build.sh)
#
# WHICH PLANE is decided by ONE input only: the image's release marker
# (/etc/ga-release, written by buildroot-external/scripts/post-build.sh from
# version.yaml, which runs before this hook). Numeric triple >= 1.4.0 means
# the certificate plane; the -rcN/-devN suffix never matters. A CA public key
# that happens to sit in the secrets mount does NOT move a pre-cut image onto
# the certificate plane — below 1.4.0 this hook removes anything it would have
# written and exits 0, so the shared plane stays exactly as it ships today.
#
# At or above the cut it needs two PUBLIC keys from the read-only secrets
# mount (the same mount the RAUC signing pair comes from, ADR-0027 D9):
#
#   ${GA_SECRETS_DIR}/ssh/ga_user_ca.pub    the user CA key(s), 1-2 lines (ceremony)
#   ${GA_SECRETS_DIR}/ssh/ga_breakglass.pub the break-glass key (paper backup)
#
# Neither is secret. They live next to the signing material so that dropping
# the real CA in after the ceremony is a file copy on the builder, not a code
# change, and so that no public repository ever names the fleet's trust anchor.
# A missing, empty, placeholder or unparseable key FAILS THE BUILD: an image
# that promises the certificate plane and trusts nobody is a fleet nobody can
# log into, and it would look healthy until someone tried.
#
# What it writes into the image (and nothing else):
#   /etc/ssh/ga_user_ca.pub
#   /etc/ssh/ga_revoked_keys                       keys sshd refuses everywhere
#                                                  (committed next to this hook)
#   /etc/ssh/sshd_config.d/50-ga-cert-plane.conf   TrustedUserCAKeys +
#                                                  AuthorizedPrincipalsFile +
#                                                  AuthorizedKeysFile + RevokedKeys
#   /usr/lib/systemd/system/sshd.service.d/zz-ga-cert-plane.conf
#                                                  sshd starts on the file it reads
#   /usr/share/ga-ssh/authorized_keys              exactly ONE line: break-glass
#                                                  (replaces the shared key)
#
# WHY sshd READS THE BAKED FILE, AND WHY THE REVOCATION LIST
# The overlay copy /root/.ssh/authorized_keys is seeded only when it is absent
# (hassos-overlay). A device that reaches this image by an OTA update keeps the
# overlay file its FIRST image wrote, so the image-side seed never reaches it.
# The two directives make the plane hold on such a device as well as on a
# fresh flash, and re-assert it on every boot:
#   * AuthorizedKeysFile names the read-only baked file FIRST, so the
#     break-glass key works whatever the overlay holds;
#   * RevokedKeys refuses every key in the baked list (the pre-cut fleet key),
#     wherever it appears — the overlay file included.
# The overlay file itself is left as it is: a slot that falls back to an older
# image reads it and keeps the access that image was built with.
# SSH-05/06/07/09/10 in tests/ga_tests/run_build_tests.sh check the result.
# -----------------------------------------------------------------------------
set -euo pipefail

SSH_CUT_TRIPLE="1.4.0"
GA_CA_PLACEHOLDER="PLACEHOLDER-REPLACE-AT-KEY-CEREMONY"
GA_SECRETS_DIR="${GA_SECRETS_DIR:-/secrets}"
CA_SRC="${GA_SECRETS_DIR}/ssh/ga_user_ca.pub"
BG_SRC="${GA_SECRETS_DIR}/ssh/ga_breakglass.pub"
DROPIN_REL="etc/ssh/sshd_config.d/50-ga-cert-plane.conf"
# Sorts AFTER sshd.service.d/hassos.conf (systemd applies drop-ins in name
# order), so its condition reset replaces the one hassos.conf sets.
UNIT_DROPIN_REL="usr/lib/systemd/system/sshd.service.d/zz-ga-cert-plane.conf"
REVOKED_REL="etc/ssh/ga_revoked_keys"
# The revocation list, committed in this repository (public keys only).
REVOKED_SRC="$(dirname "$0")/../ssh-revoked-keys"
# The pre-cut fleet-wide operator key (RSA-2048, rsa-key-20240404). Pinned
# here as a constant, never read out of the file it is checked against: a
# revocation list that has lost this key must fail the build.
GA_LEGACY_FLEET_KEY_FP="SHA256:T+Pt2vUEG+lYv0t5qTMdFyd2Kchx6mjkOR3YZaVqcjE"

log()  { echo "ssh-cert-plane: $*"; }
die()  { echo "ssh-cert-plane: FAIL: $*" >&2; exit 1; }

# "$1" (BOSvX.Y.Z[-rcN]) at or above the cut?  0 = yes, 1 = no, 2 = malformed
at_or_above_cut() {
  local rel="$1" a1 a2 a3 b1 b2 b3
  [[ "$rel" =~ ^BOSv([0-9]+)\.([0-9]+)\.([0-9]+)(-(rc|dev)[0-9]+)?$ ]] || return 2
  a1=${BASH_REMATCH[1]}; a2=${BASH_REMATCH[2]}; a3=${BASH_REMATCH[3]}
  IFS=. read -r b1 b2 b3 <<< "$SSH_CUT_TRIPLE"
  (( a1 != b1 )) && { (( a1 > b1 )) && return 0 || return 1; }
  (( a2 != b2 )) && { (( a2 > b2 )) && return 0 || return 1; }
  (( a3 >= b3 )) && return 0 || return 1
}

# Public key lines: no placeholder, 1..<max> distinct lines, each parses.
# Echoes the normalised "<type> <base64>" lines (comments dropped — a comment
# is not part of trust).
#
# The CA file may hold TWO keys: one per YubiKey, each generated ON its token
# and never exportable (key ceremony runbook). Either token can sign; losing
# one costs nothing but a rotation at the next image. The break-glass file
# holds exactly one.
pubkeys() {  # <file> <what> <max>
  local f="$1" what="$2" max="$3" n line out="" norm
  [[ -s "$f" ]] || die "$what not found or empty at $f — mount the secrets dir (docker run -v <secrets>:${GA_SECRETS_DIR}:ro) and put the key ceremony output there"
  grep -q "$GA_CA_PLACEHOLDER" "$f" && die "$what at $f is still the placeholder — the key ceremony has not happened"
  n=$(grep -cvE '^[[:space:]]*(#|$)' "$f" || true)
  (( n >= 1 && n <= max )) || die "$what at $f must hold 1..$max key line(s), found $n"
  # `|| [[ -n $line ]]`: a last line without a trailing newline is otherwise
  # dropped — and a hand-pasted key is exactly where that happens.
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+([A-Za-z0-9+/]+=*)([[:space:]].*)?$ ]] \
      || die "$what at $f: not an ed25519/ECDSA OpenSSH public key line: '${line:0:40}...'"
    norm="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    if command -v ssh-keygen >/dev/null 2>&1; then
      printf '%s\n' "$norm" | ssh-keygen -lf /dev/stdin >/dev/null 2>&1 \
        || die "$what at $f does not parse (ssh-keygen -l refused it)"
    fi
    grep -qxF "$norm" <<< "$out" && die "$what at $f lists the same key twice"
    out+="$norm"$'\n'
  done < "$f"
  [[ -n "$out" ]] || die "$what at $f: no key read"
  printf '%s' "$out"
}

# The revocation list: every non-comment line an OpenSSH public key, and the
# pinned pre-cut key among them. Needs ssh-keygen (the build container has it);
# without it the list cannot be checked, and an unchecked list fails the build.
revoked_keys() {  # <file> -> normalised "<type> <base64>" lines on stdout
  local f="$1" line out="" fp found=0 tmp
  [[ -s "$f" ]] || die "revocation list not found or empty at $f"
  command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is needed to check the revocation list $f"
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+([A-Za-z0-9+/]+=*)([[:space:]].*)?$ ]] \
      || { rm -f "$tmp"; die "revocation list $f: not an OpenSSH public key line: '${line:0:40}...'"; }
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" > "$tmp"
    fp="$(ssh-keygen -lf "$tmp" 2>/dev/null | awk '{print $2}')" || fp=""
    [[ -n "$fp" ]] || { rm -f "$tmp"; die "revocation list $f: a key line does not parse (ssh-keygen -l refused it)"; }
    [[ "$fp" == "$GA_LEGACY_FLEET_KEY_FP" ]] && found=1
    out+="$(cat "$tmp")"$'\n'
  done < "$f"
  rm -f "$tmp"
  (( found )) || die "revocation list $f does not hold the pre-cut fleet key ($GA_LEGACY_FLEET_KEY_FP)"
  printf '%s' "$out"
}

if [[ "${1:-}" == "--check" ]]; then
  rel="${2:-}"
  rc=0; at_or_above_cut "$rel" || rc=$?
  case $rc in
    0) pubkeys "$CA_SRC" "user CA public key" 2 >/dev/null
       pubkeys "$BG_SRC" "break-glass public key" 1 >/dev/null
       revoked_keys "$REVOKED_SRC" >/dev/null
       log "preflight: $rel is on the certificate plane; CA + break-glass keys present, revocation list holds the pre-cut key" ;;
    1) log "preflight: $rel is below BOSv$SSH_CUT_TRIPLE — shared plane, nothing to check" ;;
    *) die "preflight: cannot parse release '$rel'" ;;
  esac
  exit 0
fi

TARGET_DIR="${1:?usage: $0 <TARGET_DIR> | --check <GA_RELEASE>}"
REL="$(head -1 "${TARGET_DIR}/etc/ga-release" 2>/dev/null | tr -d '\r\n' || true)"

rc=0; at_or_above_cut "$REL" || rc=$?
if (( rc == 2 )); then
  # No marker at all: SSH-06 fails such an image anyway; do not guess a plane.
  log "no parseable /etc/ga-release ('$REL') — leaving the SSH plane untouched"
  exit 0
fi
if (( rc == 1 )); then
  # Below the cut: make sure nothing of the certificate plane is in the image,
  # including leftovers from an earlier build in the same output dir.
  rm -f "${TARGET_DIR}/etc/ssh/ga_user_ca.pub" "${TARGET_DIR}/${DROPIN_REL}" \
        "${TARGET_DIR}/${UNIT_DROPIN_REL}" "${TARGET_DIR}/${REVOKED_REL}"
  log "$REL is below BOSv$SSH_CUT_TRIPLE — shared plane, certificate plane not installed"
  exit 0
fi

CA_LINES="$(pubkeys "$CA_SRC" "user CA public key" 2)"
BG_LINE="$(pubkeys "$BG_SRC" "break-glass public key" 1)"
BG_LINE="${BG_LINE%$'\n'}"
grep -qxF "$BG_LINE" <<< "$CA_LINES" && die "the break-glass key is also listed as a CA key"
REVOKED_LINES="$(revoked_keys "$REVOKED_SRC")"
grep -qxF "$BG_LINE" <<< "$REVOKED_LINES" && die "the break-glass key is on the revocation list — sshd would refuse it"

install -d -m 0755 "${TARGET_DIR}/etc/ssh/sshd_config.d" "${TARGET_DIR}/usr/share/ga-ssh"
sed 's/$/ ga-user-ca/' <<< "${CA_LINES%$'\n'}" > "${TARGET_DIR}/etc/ssh/ga_user_ca.pub"
chmod 0644 "${TARGET_DIR}/etc/ssh/ga_user_ca.pub"

cat > "${TARGET_DIR}/${DROPIN_REL}" <<'CONF'
# Written at bake time by post-build.d/87-ssh-cert-plane.sh (ADR-0019 step 2).
# Present ONLY on BOSv1.4.0+ images.
#
# The one trust anchor for operator logins: a certificate signed by the
# offline GA user CA.
TrustedUserCAKeys /etc/ssh/ga_user_ca.pub
# Per-device scoping. Holds this device's hardware serial (anchor, written by
# ga-sshd-prepare) and its fleet label KIB-SON-... (written by
# ga-ssh-principal-label from ga_manager). Without this line ONE certificate
# would open EVERY device, and every single-device test would still pass.
AuthorizedPrincipalsFile /etc/ssh/principals/%u
# Static keys. The baked, read-only file comes first: it holds exactly the
# break-glass key, so break-glass works on every device running this image,
# including one updated over the air whose overlay copy (second entry) was
# written by an older image. sshd takes the FIRST AuthorizedKeysFile it reads,
# and sshd_config Includes this drop-in before its own AuthorizedKeysFile line.
AuthorizedKeysFile /usr/share/ga-ssh/authorized_keys /root/.ssh/authorized_keys
# Keys refused whichever file lists them. Holds the pre-cut fleet-wide key, so
# an overlay file carried over from an older image cannot authorise it.
RevokedKeys /etc/ssh/ga_revoked_keys
CONF
chmod 0644 "${TARGET_DIR}/${DROPIN_REL}"

printf '%s\n' "$REVOKED_LINES" > "${TARGET_DIR}/${REVOKED_REL}"
chmod 0644 "${TARGET_DIR}/${REVOKED_REL}"

install -d -m 0755 "$(dirname "${TARGET_DIR}/${UNIT_DROPIN_REL}")"
cat > "${TARGET_DIR}/${UNIT_DROPIN_REL}" <<'UNIT'
# Written at bake time by post-build.d/87-ssh-cert-plane.sh. Present ONLY on
# BOSv1.4.0+ images.
#
# hassos.conf gates sshd on the overlay copy /root/.ssh/authorized_keys. On
# the certificate plane sshd reads the baked break-glass file first (see
# /etc/ssh/sshd_config.d/50-ga-cert-plane.conf), so the "never listen with
# nothing authorised" gate moves to that file. The empty assignment resets the
# condition list set by hassos.conf; this file sorts after it on purpose.
[Unit]
ConditionFileNotEmpty=
ConditionFileNotEmpty=/usr/share/ga-ssh/authorized_keys
UNIT
chmod 0644 "${TARGET_DIR}/${UNIT_DROPIN_REL}"

# The shared operator key leaves the image here. Exactly one line remains:
# the break-glass key, whose private half exists only offline.
printf '%s ga-breakglass\n' "$BG_LINE" > "${TARGET_DIR}/usr/share/ga-ssh/authorized_keys"
chmod 0644 "${TARGET_DIR}/usr/share/ga-ssh/authorized_keys"

ca_fps=$(ssh-keygen -lf "${TARGET_DIR}/etc/ssh/ga_user_ca.pub" 2>/dev/null | awk '{print $2}' | tr '\n' ' ' || true)
log "$REL — certificate plane installed (user CA: ${ca_fps:-<ssh-keygen unavailable>}; break-glass is the only baked static key; $(grep -c . "${TARGET_DIR}/${REVOKED_REL}") key(s) on the revocation list)"
