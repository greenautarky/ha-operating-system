#!/usr/bin/env bash
# =============================================================================
# selftest.sh — SSH-05..07 must go BOTH ways, against fixture build trees.
# =============================================================================
# WHY THIS EXISTS
# ---------------
# SSH-06 (ADR-0019) is a comparison: what the image's release marker declares
# about its SSH access plane, against what the image's files actually are. A
# comparison is only worth having if it can come out both ways, and neither
# outcome is observable in a normal build — a correct image prints one PASS
# line, and a gate that can only print PASS is decoration.
#
# So this runs the LIVE run_build_tests.sh (never a copy of the checks) against
# build trees whose correct verdict is known in advance, and asserts only on
# the SSH-05/06/07 lines. Everything else the runner says about a fixture tree
# is noise by construction and is filtered out.
#
# must-pass matters as much as must-fail here, and one case is special: the
# CURRENT shape of the image must stay green, or this gate blocks every build
# on the pre-cut line the day it lands.
#
# Fully offline: temp trees, no build, no device, ~2 seconds.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RUNNER="$ROOT/tests/ga_tests/run_build_tests.sh"
LEGACY_KEY="$ROOT/tests/gates/ssh_posture/legacy-fleet-key.pub"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
fails=0; ran=0
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }

# FAIL, never skip, if the subject or its fixture disappears.
[[ -r "$RUNNER"     ]] || { echo "FATAL: $RUNNER missing"; exit 1; }
[[ -s "$LEGACY_KEY" ]] || { echo "FATAL: $LEGACY_KEY missing"; exit 1; }
command -v ssh-keygen >/dev/null 2>&1 || { echo "FATAL: ssh-keygen required"; exit 1; }

# The gate's pinned constants must still describe the fixtures. If they drift,
# the must-fail cases start passing for the wrong reason and the suite goes
# green while measuring nothing.
PINNED_FP="$(sed -nE 's/^GA_LEGACY_FLEET_KEY_FP="(.+)"$/\1/p' "$RUNNER" | head -1)"
PLACEHOLDER="$(sed -nE 's/^GA_CA_PLACEHOLDER="(.+)"$/\1/p' "$RUNNER" | head -1)"
FIXTURE_FP="$(ssh-keygen -lf "$LEGACY_KEY" | awk '{print $2}')"
[[ -n "$PINNED_FP" && -n "$PLACEHOLDER" ]] || {
  echo "FATAL: could not extract the pinned constants from $RUNNER"; exit 1; }
[[ "$PINNED_FP" == "$FIXTURE_FP" ]] || {
  echo "FATAL: pinned fingerprint ($PINNED_FP) != fixture ($FIXTURE_FP)"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ssh-keygen -q -t ed25519 -N '' -C breakglass -f "$WORK/bg" || exit 1
ssh-keygen -q -t ed25519 -N '' -C ga-user-ca  -f "$WORK/ca" || exit 1
BREAKGLASS="$(cat "$WORK/bg.pub")"
REAL_CA="$(cat "$WORK/ca.pub")"
LEGACY="$(cat "$LEGACY_KEY")"

DROPBEAR_OK=$'[Unit]\nConditionFileNotEmpty=/root/.ssh/authorized_keys\n'
SSHD_OK=$'[Unit]\nConditionFileNotEmpty=/root/.ssh/authorized_keys\n[Service]\nExecStartPre=\nExecStartPre=/usr/libexec/ga-sshd-prepare\n'
SSHD_NOCLEAR=$'[Unit]\nConditionFileNotEmpty=/root/.ssh/authorized_keys\n[Service]\nExecStartPre=/usr/libexec/ga-sshd-prepare\n'
SSHD_BINS="usr/sbin/sshd,usr/bin/ssh-keygen,usr/libexec/ga-sshd-prepare,usr/lib/systemd/system/sshd.service"
SSHD_SHARED=$'Port 22222\nAuthorizedKeysFile /root/.ssh/authorized_keys\nPasswordAuthentication no\n'
SSHD_FULL=$'TrustedUserCAKeys /etc/ssh/ga_user_ca.pub\nAuthorizedPrincipalsFile /etc/ssh/principals/%u\nPasswordAuthentication no\n'

# mk <name> <ga-release> <authorized_keys|-> <sshd_config|-> <ca_pub|-> <dropbear|-> [<sshd-dropin|->] [<files>]
#   <files>: comma-separated paths created (executable, non-empty) under target/
mk() {
  local d="$WORK/$1"; shift
  local rel="$1" ak="$2" cfg="$3" ca="$4" db="$5" sd="${6:--}" files="${7:-}"
  mkdir -p "$d/target/etc/ssh" "$d/target/usr/share/ga-ssh" \
           "$d/target/usr/lib/systemd/system/dropbear.service.d" \
           "$d/target/usr/lib/systemd/system/sshd.service.d"
  printf '%s\n' "$rel" > "$d/target/etc/ga-release"
  [[ "$ak"  != "-" ]] && printf '%s\n' "$ak"  > "$d/target/usr/share/ga-ssh/authorized_keys"
  [[ "$cfg" != "-" ]] && printf '%s'   "$cfg" > "$d/target/etc/ssh/sshd_config"
  [[ "$ca"  != "-" ]] && printf '%s\n' "$ca"  > "$d/target/etc/ssh/ga_user_ca.pub"
  [[ "$db"  != "-" ]] && printf '%s'   "$db"  > "$d/target/usr/lib/systemd/system/dropbear.service.d/hassos.conf"
  [[ "$sd"  != "-" ]] && printf '%s'   "$sd"  > "$d/target/usr/lib/systemd/system/sshd.service.d/hassos.conf"
  local f; IFS=, read -ra _fl <<< "$files"
  for f in "${_fl[@]}"; do [[ -n "$f" ]] || continue; mkdir -p "$d/target/$(dirname "$f")"; printf 'x\n' > "$d/target/$f"; chmod +x "$d/target/$f"; done
  printf '%s' "$d"
}

# verdict <dir> <check-id>  ->  "PASS" | "FAIL" | "ABSENT"
verdict() {
  local line
  line="$(bash "$RUNNER" "$1" 2>&1 | grep -E "  (PASS|FAIL)  $2:" | head -1)"
  case "$line" in
    *"  PASS  "*) printf 'PASS' ;;
    *"  FAIL  "*) printf 'FAIL' ;;
    *)            printf 'ABSENT' ;;
  esac
}

expect() {  # <want> <dir> <check-id> <description>
  local got; got="$(verdict "$2" "$3")"; ran=$((ran + 1))
  if [[ "$got" == "$1" ]]; then ok "$3 $1 — $4"
  else bad "$3 → got $got, want $1 — $4"; fi
}

echo "── must FAIL (the gate must not wave these through) ──"

d="$(mk promises-ca-is-shared BOSv1.4.0-rc1 "$LEGACY" - - "$DROPBEAR_OK")"
expect FAIL "$d" SSH-06 "marker promises the cert plane, legacy fleet key still baked"

d="$(mk promises-ca-no-trust BOSv1.4.0-rc1 "$BREAKGLASS" $'PasswordAuthentication no\n' - "$DROPBEAR_OK")"
expect FAIL "$d" SSH-06 "marker promises the cert plane, no TrustedUserCAKeys"

d="$(mk ahead-of-marker BOSv1.3.0-rc10 "$BREAKGLASS" "$SSHD_FULL" "$REAL_CA" -)"
expect FAIL "$d" SSH-06 "image is on the cert plane but the marker says otherwise"

d="$(mk malformed-marker NOT-A-RELEASE "$BREAKGLASS" - - "$DROPBEAR_OK")"
expect FAIL "$d" SSH-06 "release marker unreadable — the applicable contract is unknown"

d="$(mk ca-placeholder BOSv1.4.0-rc1 "$BREAKGLASS" "$SSHD_FULL" "ssh-ed25519 AAAA$PLACEHOLDER ga-user-ca" -)"
expect FAIL "$d" SSH-07 "CA public key is still the build placeholder"

d="$(mk ca-missing BOSv1.4.0-rc1 "$BREAKGLASS" "$SSHD_FULL" - -)"
expect FAIL "$d" SSH-07 "cert plane with no CA public key baked"

d="$(mk no-principals BOSv1.4.0-rc1 "$BREAKGLASS" $'TrustedUserCAKeys /etc/ssh/ga_user_ca.pub\n' "$REAL_CA" -)"
expect FAIL "$d" SSH-05 "cert plane without AuthorizedPrincipalsFile — one cert would open every device"

d="$(mk dropbear-weakened BOSv1.3.0-rc10 "$LEGACY" - - $'[Unit]\n')"
expect FAIL "$d" SSH-05 "shared plane with the dropbear authorized_keys condition removed"

# ADR-0019 step 1: OpenSSH serves the SHARED plane. Same invariant, new unit.
d="$(mk sshd-weakened BOSv1.3.0-rc47 "$LEGACY" "$SSHD_SHARED" - - $'[Unit]\nRequiresMountsFor=/etc/ssh/keys\n')"
expect FAIL "$d" SSH-05 "shared plane on sshd with the authorized_keys condition removed"

d="$(mk both-servers BOSv1.3.0-rc47 "$LEGACY" "$SSHD_SHARED" - "$DROPBEAR_OK" "$SSHD_OK")"
expect FAIL "$d" SSH-05 "dropbear AND sshd drop-ins both present — the swap is half done"

d="$(mk no-server-unit BOSv1.3.0-rc47 "$LEGACY" "$SSHD_SHARED" - - -)"
expect FAIL "$d" SSH-05 "shared plane with no server drop-in at all"

# SSH-08: the sshd image must be COMPLETE. Each case removes exactly one thing.
d="$(mk sshd-no-keygen BOSv1.3.0-rc47 "$LEGACY" "$SSHD_SHARED" - - "$SSHD_OK" "usr/sbin/sshd,usr/libexec/ga-sshd-prepare,usr/lib/systemd/system/sshd.service")"
expect FAIL "$d" SSH-08 "sshd image without ssh-keygen (prepare + posture would both fail at boot)"

d="$(mk sshd-keygen-A-kept BOSv1.3.0-rc47 "$LEGACY" "$SSHD_SHARED" - - "$SSHD_NOCLEAR" "$SSHD_BINS")"
expect FAIL "$d" SSH-08 "drop-in does not clear the upstream ssh-keygen -A ExecStartPre"

d="$(mk sshd-dropbear-left BOSv1.3.0-rc47 "$LEGACY" "$SSHD_SHARED" - - "$SSHD_OK" "$SSHD_BINS,usr/sbin/dropbear")"
expect FAIL "$d" SSH-08 "dropbear binary left in an sshd image"

d="$(mk sshd-gesftp-left BOSv1.3.0-rc47 "$LEGACY" "$SSHD_SHARED" - - "$SSHD_OK" "$SSHD_BINS,usr/libexec/gesftpserver")"
expect FAIL "$d" SSH-08 "gesftpserver left in an sshd image"

echo "── must PASS (a gate that only fails is a blocked pipeline, not a check) ──"

# The shape the repository is in TODAY. If this goes red the gate blocks every
# build on the pre-cut line from the day it lands.
d="$(mk todays-image BOSv1.3.0-rc10 "$LEGACY" - - "$DROPBEAR_OK")"
expect PASS "$d" SSH-05 "pre-swap image — dropbear condition intact"
expect PASS "$d" SSH-06 "pre-swap image — marker and content both say shared"
expect ABSENT "$d" SSH-08 "pre-swap image — the sshd completeness check does not apply to dropbear"

# The shape the repository is in TODAY (ADR-0019 step 1): sshd on the shared
# plane, no CA directive, legacy key still baked. If this goes red the gate
# blocks every build on the current line from the day it lands.
d="$(mk todays-image-sshd BOSv1.3.0-rc47 "$LEGACY" "$SSHD_SHARED" - - "$SSHD_OK" "$SSHD_BINS")"
expect PASS "$d" SSH-05 "today's image — sshd condition intact on the shared plane"
expect PASS "$d" SSH-06 "today's image — marker and content both say shared (sshd, no CA)"
expect ABSENT "$d" SSH-07 "today's image — the CA check does not apply on the shared plane"
expect PASS "$d" SSH-08 "today's image — OpenSSH server complete, nothing of dropbear left"

# The shape BOSv1.4.0-rc1 is meant to have.
d="$(mk cut-image BOSv1.4.0-rc1 "$BREAKGLASS" "$SSHD_FULL" "$REAL_CA" -)"
expect PASS "$d" SSH-05 "cut image — certificates are scoped per device"
expect PASS "$d" SSH-06 "cut image — marker and content both say ca"
expect PASS "$d" SSH-07 "cut image — a real CA public key is baked"

# SSH-07 is scoped to the cert plane: it must stay silent on a pre-cut image
# rather than failing it for a file that plane never has.
d="$(mk pre-cut-no-ca BOSv1.3.0-rc10 "$LEGACY" - - "$DROPBEAR_OK")"
expect ABSENT "$d" SSH-07 "pre-cut image — the CA check does not apply"

echo
# Assert coverage, not exit code: a suite that ran nothing is a failure.
if (( ran < 14 )); then echo "${RED}FAIL${NC}  only $ran cases ran — expected at least 14"; exit 1; fi
if (( fails > 0 )); then echo "${RED}${fails} of ${ran} case(s) failed${NC}"; exit 1; fi
echo "${GRN}all ${ran} cases passed${NC}"
