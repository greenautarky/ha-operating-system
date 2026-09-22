#!/usr/bin/env bash
# =============================================================================
# selftest.sh — ga-ssh-posture must go BOTH ways, for the right reasons.
# =============================================================================
# WHY THIS EXISTS
# ---------------
# ga-ssh-posture answers one question — "is this device on the certificate
# plane?" — and fleet-manager compares its answer against what the device's
# release marker promises (ADR-0019 §2). Two failure modes make that comparison
# worthless, and neither is visible in review or in a green build:
#
#   * a sensor that can only say "shared" turns every cut device into a false
#     alarm, and the alarm gets trained away within a week;
#   * a sensor that says "ca" too easily hides the one state the cut exists to
#     eliminate — a device that trusts a CA while still carrying the pre-cut
#     fleet-wide operator key.
#
# So this suite runs the LIVE script (never a copy of its logic) against inputs
# whose correct verdict is known in advance, in both directions.
#
# must-pass is not padding: the "ca" cases are what stop the sensor from being
# rewritten into something that always fails closed and therefore says nothing.
#
# Fully offline: fixture trees in a temp dir, no device, no build.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# The LIVE sensor. Not a copy — a self-test that re-declares the logic stays
# green while the real thing rots, which is the failure class this file exists
# to prevent.
SENSOR="$ROOT/buildroot-external/rootfs-overlay/usr/libexec/ga-ssh-posture"
LEGACY_KEY="$HERE/legacy-fleet-key.pub"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
fails=0; ran=0

bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }

# If the sensor or the known-bad fixture goes missing, FAIL — never skip.
# A self-test that quietly stops finding its subject is the same as no gate.
[[ -x "$SENSOR"      ]] || { echo "FATAL: $SENSOR missing or not executable"; exit 1; }
[[ -s "$LEGACY_KEY"  ]] || { echo "FATAL: $LEGACY_KEY missing"; exit 1; }
command -v ssh-keygen >/dev/null 2>&1 || { echo "FATAL: ssh-keygen required"; exit 1; }

# The pinned constant and the fixture must describe the same key. If they drift,
# every "legacy key present" case below silently starts passing for the wrong
# reason — the gate would go green while measuring nothing.
PINNED_FP="$(sed -nE 's/^GA_LEGACY_FLEET_KEY_FP="(.+)"$/\1/p' "$SENSOR" | head -1)"
FIXTURE_FP="$(ssh-keygen -lf "$LEGACY_KEY" | awk '{print $2}')"
if [[ -z "$PINNED_FP" ]]; then
  echo "FATAL: could not extract GA_LEGACY_FLEET_KEY_FP from the sensor"; exit 1
fi
if [[ "$PINNED_FP" != "$FIXTURE_FP" ]]; then
  echo "FATAL: pinned fingerprint ($PINNED_FP) != fixture ($FIXTURE_FP)"; exit 1
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Build a device-shaped fixture tree.
#   $1 name  $2 sshd_config body ("" = no file)  $3 CA file body ("-" = absent)
#   $4 authorized_keys body ("-" = absent)  $5 drop-in body ("" = none)
mk() {
  local name="$1" cfg="$2" ca="$3" ak="$4" dropin="${5:-}"
  local d="$WORK/$name"
  mkdir -p "$d/etc/ssh/sshd_config.d" "$d/root/.ssh"
  [[ -n "$cfg"    ]] && printf '%s\n' "$cfg"    > "$d/etc/ssh/sshd_config"
  [[ -n "$dropin" ]] && printf '%s\n' "$dropin" > "$d/etc/ssh/sshd_config.d/10-ga.conf"
  [[ "$ca" != "-" ]] && printf '%s' "$ca"       > "$d/etc/ssh/ga_user_ca.pub"
  [[ "$ak" != "-" ]] && printf '%s\n' "$ak"     > "$d/root/.ssh/authorized_keys"
  printf '%s' "$d"
}

verdict() {
  local d="$1"
  GA_SSHD_CONFIG="$d/etc/ssh/sshd_config" \
  GA_SSHD_CONFIG_DIR="$d/etc/ssh/sshd_config.d" \
  GA_AUTHORIZED_KEYS="$d/root/.ssh/authorized_keys" \
  "$SENSOR" 2>/dev/null
}

expect() {  # $1 want  $2 dir  $3 description
  local want="$1" got; got="$(verdict "$2")"; ran=$((ran + 1))
  if [[ "$got" == "$want" ]]; then ok "$3 → $got"
  else bad "$3 → got '$got', want '$want'"; fi
}

BREAKGLASS="$(ssh-keygen -q -t ed25519 -N '' -C breakglass -f "$WORK/bg" && cat "$WORK/bg.pub")"
LEGACY="$(cat "$LEGACY_KEY")"

_ca_cfg() { printf 'TrustedUserCAKeys %s/etc/ssh/ga_user_ca.pub\n' "$1"; }

echo "── must be 'shared' (the sensor must NOT wave these through) ──"

d="$(mk no-config "" "-" "$BREAKGLASS")"
expect shared "$d" "no sshd_config at all"

d="$(mk no-ca "PasswordAuthentication no" "-" "$BREAKGLASS")"
expect shared "$d" "sshd_config without TrustedUserCAKeys"

d="$(mk ca-missing "TrustedUserCAKeys /nonexistent/ga_user_ca.pub" "-" "$BREAKGLASS")"
expect shared "$d" "TrustedUserCAKeys points at a missing file"

d="$(mk ca-empty placeholder "" "$BREAKGLASS")"
_ca_cfg "$d" > "$d/etc/ssh/sshd_config"
expect shared "$d" "TrustedUserCAKeys points at an EMPTY file"

# ── the case the whole cut is about ──
d="$(mk legacy-present placeholder "ssh-ed25519 AAAAfakeca ga-user-ca" "$LEGACY")"
_ca_cfg "$d" > "$d/etc/ssh/sshd_config"
expect shared "$d" "CA trusted BUT the pre-cut fleet key is still in authorized_keys"

d="$(mk legacy-among-others placeholder "ssh-ed25519 AAAAfakeca ga-user-ca" \
      "$BREAKGLASS
$LEGACY")"
_ca_cfg "$d" > "$d/etc/ssh/sshd_config"
expect shared "$d" "legacy key hidden among other keys"

d="$(mk legacy-with-comment placeholder "ssh-ed25519 AAAAfakeca ga-user-ca" \
      "# operator keys
$LEGACY")"
_ca_cfg "$d" > "$d/etc/ssh/sshd_config"
expect shared "$d" "legacy key after a comment line"

# The regression this suite already caught once: a file whose LAST line has no
# trailing newline. `while read` drops it, so the legacy key hides in exactly
# the position a hand-edited authorized_keys most often puts it.
d="$(mk legacy-no-trailing-newline placeholder "ssh-ed25519 AAAAfakeca ga-user-ca" "-")"
_ca_cfg "$d" > "$d/etc/ssh/sshd_config"
printf '%s' "$LEGACY" > "$d/root/.ssh/authorized_keys"   # deliberately no \n
expect shared "$d" "legacy key as last line WITHOUT a trailing newline"

# ssh-keygen unavailable → must fail CLOSED, never optimistic.
d="$(mk no-sshkeygen placeholder "ssh-ed25519 AAAAfakeca ga-user-ca" "$BREAKGLASS")"
_ca_cfg "$d" > "$d/etc/ssh/sshd_config"
got="$(PATH=/nonexistent \
       GA_SSHD_CONFIG="$d/etc/ssh/sshd_config" \
       GA_SSHD_CONFIG_DIR="$d/etc/ssh/sshd_config.d" \
       GA_AUTHORIZED_KEYS="$d/root/.ssh/authorized_keys" \
       /bin/sh "$SENSOR" 2>/dev/null)"
ran=$((ran + 1))
if [[ "$got" == "shared" ]]; then ok "ssh-keygen unavailable → shared (fail closed)"
else bad "ssh-keygen unavailable → got '$got', want 'shared'"; fi

echo "── must be 'ca' (must-pass — a sensor that only says 'shared' says nothing) ──"

d="$(mk clean placeholder "ssh-ed25519 AAAAfakeca ga-user-ca" "$BREAKGLASS")"
_ca_cfg "$d" > "$d/etc/ssh/sshd_config"
expect ca "$d" "CA trusted, only the break-glass key present"

d="$(mk via-dropin "PasswordAuthentication no" "ssh-ed25519 AAAAfakeca ga-user-ca" "$BREAKGLASS")"
_ca_cfg "$d" > "$d/etc/ssh/sshd_config.d/10-ga.conf"
expect ca "$d" "CA configured through sshd_config.d"

d="$(mk no-authorized-keys placeholder "ssh-ed25519 AAAAfakeca ga-user-ca" "-")"
_ca_cfg "$d" > "$d/etc/ssh/sshd_config"
expect ca "$d" "CA trusted, no authorized_keys file at all"

d="$(mk comments-only placeholder "ssh-ed25519 AAAAfakeca ga-user-ca" \
      "# nothing but a comment
")"
_ca_cfg "$d" > "$d/etc/ssh/sshd_config"
expect ca "$d" "CA trusted, authorized_keys holds only comments"

echo
# Assert COVERAGE, not exit code (norm N9): a suite that ran zero cases is a
# failure, however green it looks.
if (( ran < 13 )); then
  echo "${RED}FAIL${NC}  only $ran cases ran — expected at least 13"
  exit 1
fi
if (( fails > 0 )); then
  echo "${RED}${fails} of ${ran} case(s) failed${NC}"; exit 1
fi
echo "${GRN}all ${ran} cases passed${NC}"
