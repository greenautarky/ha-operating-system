#!/usr/bin/env bash
# =============================================================================
# sshd_dryrun.sh — the certificate plane against a REAL sshd, end to end
# =============================================================================
# ADR-0019 step 2 — the local dry run of the key ceremony, and a CI gate.
#
# Everything that decides accept/refuse on a device is the LIVE code:
#   the image's sshd_config  +  the drop-in the bake hook (87-ssh-cert-plane)
#   writes  +  the host key and anchor from ga-sshd-prepare  +  the label from
#   ga-ssh-principal-label/ga-ssh-principals  +  certificates from
#   scripts/ops/ga-sign-ssh-cert.sh.
# Only the PATHS are moved into a temp dir, the port is a free local one, and
# sshd runs unprivileged as the invoking user (so the principals file is named
# after that user instead of root). The CAs are throwaway SOFTWARE keys of the
# same algorithms the YubiKeys produce (ECDSA P-256 PIV, and ed25519).
#
# THE DEVICE IT MODELS IS ONE UPDATED OVER THE AIR, not a fresh flash. Its
# overlay authorized_keys was written by a pre-cut image (the shared-plane seed,
# with the pre-cut fleet key) and does NOT hold the break-glass key, because the
# overlay is seeded only when absent. A fresh flash differs only in that file
# holding the break-glass key, which is the easier case. So the break-glass key
# must work from the baked file, and the pre-cut key must be refused by the
# baked revocation list, whatever the overlay holds.
#
# What it cannot prove — and the run on a real canary must: the real CA from the
# YubiKeys, the real hardware serial, systemd ordering, the label hand-over from
# ga_manager, and the device's OpenSSH build. Nor can it log in with the pre-cut
# key itself (its private half is not here): that the list HOLDS it is proven by
# fingerprint; that sshd REFUSES what the list holds is proven with a throwaway
# key appended to the run copy of the same list.
#
# Usage: sshd_dryrun.sh [-v]    (needs /usr/sbin/sshd, ssh, ssh-keygen)
#
# TOKEN MODE (key ceremony, step "prove the token before it is baked"):
#   GA_DRYRUN_TOKEN_CA_PUB=<the token's exported CA .pub> \
#   GA_DRYRUN_PKCS11=<path to libykcs11.so> sshd_dryrun.sh
# replaces software CA A with the REAL YubiKey: the image trusts the real CA
# public key and the accepting certificates are signed ON the token through
# the sign script's PKCS#11 path (PIN + touch per signature). Proves the
# token, the exported public key and the sign script agree before anything is
# baked.
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OVL="$ROOT/buildroot-external/rootfs-overlay"
HOOK="$ROOT/buildroot-ihost/board/sonoff/ihost/post-build.d/87-ssh-cert-plane.sh"
SIGN="$ROOT/scripts/ops/ga-sign-ssh-cert.sh"
SSHD="${SSHD:-/usr/sbin/sshd}"
VERBOSE=0; [[ "${1:-}" == "-v" ]] && VERBOSE=1

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
fails=0; ran=0
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }
for f in "$SSHD" "$HOOK" "$SIGN" "$OVL/etc/ssh/sshd_config"; do [[ -e "$f" ]] || { echo "FATAL: $f missing"; exit 1; }; done
command -v ssh >/dev/null && command -v ssh-keygen >/dev/null || { echo "FATAL: ssh + ssh-keygen required"; exit 1; }

ME="$(id -un)"
# NOT under /tmp: sshd's StrictModes walks every directory up to / and refuses
# authorized_keys and the principals file below a world-writable one — which
# is exactly the device failure ga-sshd-prepare guards against, reproduced by
# the test harness instead of the image.
W="$(mktemp -d -p "${GA_DRYRUN_DIR:-$HOME}" .ga-sshd-dryrun.XXXXXX)"; chmod 0755 "$W"
cleanup() { [[ -f "$W/sshd.pid" ]] && kill "$(cat "$W/sshd.pid")" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
unset SSH_AUTH_SOCK

LABEL="KIB-SON-00000901"; ANCHOR="DRYRUNHWSERIAL0901"; OTHER="KIB-SON-00000907"

echo "── 1. keys (throwaway; the ceremony makes the real ones) ──"
mkdir -p "$W/secrets/ssh" "$W/keys"
ssh-keygen -q -t ecdsa -b 256 -N '' -C yubikey-a-piv -f "$W/keys/ca_a"   # stands in for YubiKey A (PIV P-256)
ssh-keygen -q -t ed25519      -N '' -C yubikey-b     -f "$W/keys/ca_b"   # stands in for YubiKey B
ssh-keygen -q -t ed25519      -N '' -C rogue-ca      -f "$W/keys/rogue"
ssh-keygen -q -t ed25519      -N '' -C breakglass    -f "$W/keys/bg"
ssh-keygen -q -t ed25519      -N '' -C operator      -f "$W/keys/op"
ssh-keygen -q -t ed25519      -N '' -C shared-plain  -f "$W/keys/plain"
ssh-keygen -q -t ed25519      -N '' -C revoked-standin -f "$W/keys/revoked"   # stands in for a revoked key
ssh-keygen -q -t ed25519      -N '' -C overlay-extra -f "$W/keys/extra"     # a key an older image's overlay authorised
# The pinned fingerprint of the pre-cut key, from the posture sensor that has
# carried it since the cut was designed (the hook pins the same value).
LEGACY_FP="$(sed -nE 's/^GA_LEGACY_FLEET_KEY_FP="(.+)"$/\1/p' "$OVL/usr/libexec/ga-ssh-posture" | head -1)"
[[ -n "$LEGACY_FP" ]] || { echo "FATAL: could not read GA_LEGACY_FLEET_KEY_FP from ga-ssh-posture"; exit 1; }
TOKEN=0
if [[ -n "${GA_DRYRUN_TOKEN_CA_PUB:-}" || -n "${GA_DRYRUN_PKCS11:-}" ]]; then
  [[ -r "${GA_DRYRUN_TOKEN_CA_PUB:-}" && -r "${GA_DRYRUN_PKCS11:-}" ]] \
    || { echo "FATAL: token mode needs BOTH GA_DRYRUN_TOKEN_CA_PUB and GA_DRYRUN_PKCS11"; exit 1; }
  TOKEN=1; cp "$GA_DRYRUN_TOKEN_CA_PUB" "$W/keys/ca_a.pub"; rm -f "$W/keys/ca_a"
  echo "  TOKEN MODE: CA A is the hardware token ($(ssh-keygen -lf "$W/keys/ca_a.pub" | awk '{print $2}'))"
fi
cat "$W/keys/ca_a.pub" "$W/keys/ca_b.pub" > "$W/secrets/ssh/ga_user_ca.pub"
cp "$W/keys/bg.pub" "$W/secrets/ssh/ga_breakglass.pub"
echo "  CA A: $(ssh-keygen -lf "$W/keys/ca_a.pub" | awk '{print $2, $NF}')"
echo "  CA B: $(ssh-keygen -lf "$W/keys/ca_b.pub" | awk '{print $2, $NF}')"

echo "── 2. bake: the LIVE hook turns a BOSv1.4.0-rc1 tree onto the certificate plane ──"
T="$W/target"; mkdir -p "$T/etc/ssh" "$T/usr/share/ga-ssh"
echo "BOSv1.4.0-rc1" > "$T/etc/ga-release"
cp "$OVL/etc/ssh/sshd_config" "$T/etc/ssh/sshd_config"
cp "$OVL/usr/share/ga-ssh/authorized_keys" "$T/usr/share/ga-ssh/authorized_keys"
GA_SECRETS_DIR="$W/secrets" bash "$HOOK" "$T" | sed 's/^/  /' || { echo "FATAL: hook failed"; exit 1; }

echo "── 3. boot after an OTA update: LIVE ga-sshd-prepare (host key + anchor) and the label bridge ──"
R="$W/run"; mkdir -p "$R/etc/ssh/keys" "$R/etc/ssh/principals" "$R/etc/ssh/sshd_config.d" "$R/root/.ssh" "$R/usr/share/ga-ssh"
chmod 0755 "$R" "$R/etc" "$R/etc/ssh" "$R/etc/ssh/principals" "$R/usr" "$R/usr/share" "$R/usr/share/ga-ssh"; chmod 0700 "$R/root/.ssh"
cp "$T/etc/ssh/ga_user_ca.pub" "$R/etc/ssh/"
cp "$T/etc/ssh/sshd_config.d/50-ga-cert-plane.conf" "$R/etc/ssh/sshd_config.d/"
[[ -s "$T/etc/ssh/ga_revoked_keys" ]] && cp "$T/etc/ssh/ga_revoked_keys" "$R/etc/ssh/"
cp "$T/usr/share/ga-ssh/authorized_keys" "$R/usr/share/ga-ssh/authorized_keys"
# The throwaway key goes into the RUN copy only; the baked list is checked as baked.
[[ -f "$R/etc/ssh/ga_revoked_keys" ]] && awk '{print $1" "$2}' "$W/keys/revoked.pub" >> "$R/etc/ssh/ga_revoked_keys"
# The overlay file a pre-cut image left behind: its seed (pre-cut fleet key),
# plus keys that image authorised. No break-glass line.
{ cat "$OVL/usr/share/ga-ssh/authorized_keys"; cat "$W/keys/revoked.pub" "$W/keys/extra.pub"; } > "$R/root/.ssh/authorized_keys"
chmod 0600 "$R/root/.ssh/authorized_keys"
grep -qF "$(awk '{print $2}' "$W/keys/bg.pub")" "$R/root/.ssh/authorized_keys" && { echo "FATAL: the modelled overlay holds the break-glass key"; exit 1; }
ssh-keygen -lf "$R/root/.ssh/authorized_keys" 2>/dev/null | grep -qF "$LEGACY_FP" || { echo "FATAL: the modelled overlay lacks the pre-cut fleet key"; exit 1; }
echo "  overlay authorized_keys (pre-cut): $(grep -cE '^(ssh-|ecdsa-)' "$R/root/.ssh/authorized_keys") keys, pre-cut fleet key among them, no break-glass"
printf '%s\0' "$ANCHOR" > "$W/dt-serial"
GA_SSHD_KEYDIR="$R/etc/ssh/keys" GA_SSH_CA_PUB="$R/etc/ssh/ga_user_ca.pub" \
GA_SSH_PRINCIPALS_DIR="$R/etc/ssh/principals" GA_SSH_PRINCIPALS_USER="$ME" \
GA_SSH_PRINCIPALS_BIN="$OVL/usr/libexec/ga-ssh-principals" GA_DT_SERIAL="$W/dt-serial" \
GA_CPUINFO=/dev/null GA_SSHD_PREPARE_VAR_EMPTY=0 sh "$OVL/usr/libexec/ga-sshd-prepare" 2>&1 | sed 's/^/  /'
printf '%s\n' "$LABEL" > "$W/gm-label"         # what ga_manager's ssh-principals-write leaves in its /data
printf '%s\n' "$LABEL" > "$W/ga-device-label"  # this device's own label, which it must equal
GA_SSH_CA_PUB="$R/etc/ssh/ga_user_ca.pub" GA_SSH_LABEL_BRIDGE="$W/gm-label" GA_DEVICE_LABEL_FILE="$W/ga-device-label" \
GA_SSH_PRINCIPALS_DIR="$R/etc/ssh/principals" GA_SSH_PRINCIPALS_USER="$ME" \
GA_SSH_PRINCIPALS_BIN="$OVL/usr/libexec/ga-ssh-principals" sh "$OVL/usr/libexec/ga-ssh-principal-label" 2>&1 | sed 's/^/  /'
echo "  principals file: $(tr '\n' ' ' < "$R/etc/ssh/principals/$ME")"

# Relocate the device paths into $R; everything else in the config is verbatim.
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
for f in "$T/etc/ssh/sshd_config" "$R/etc/ssh/sshd_config.d/50-ga-cert-plane.conf"; do
  out="$R/etc/ssh/${f##*/}"; [[ "$f" == *.conf ]] && out="$R/etc/ssh/sshd_config.d/${f##*/}"
  sed -e "s#/etc/ssh/#$R/etc/ssh/#g" -e "s#/root/.ssh/#$R/root/.ssh/#g" -e "s#/usr/share/ga-ssh/#$R/usr/share/ga-ssh/#g" \
      -e "s#^Port 22222#Port $PORT#" "$f" > "$out.tmp" && mv "$out.tmp" "$out"
done
"$SSHD" -t -f "$R/etc/ssh/sshd_config" -o PidFile="$W/sshd.pid" || { echo "FATAL: sshd -t rejected the image config"; exit 1; }
echo "── effective config (sshd -T) ──"
"$SSHD" -T -f "$R/etc/ssh/sshd_config" -o PidFile="$W/sshd.pid" -C "user=$ME,host=localhost,addr=127.0.0.1" 2>/dev/null \
  | grep -E '^(port|trustedusercakeys|authorizedprincipalsfile|authorizedkeysfile|revokedkeys|passwordauthentication|permitrootlogin|loglevel) ' | sed "s#$W#<tmp>#g; s/^/  /"
# OpenSSH >= 9.8 penalises a source address after failed logins and then DROPS
# its connections before authentication. This run fails logins on purpose, so
# the penalty would turn every later case into "refused" for the wrong reason
# (it did: the break-glass case went red behind it). Switched off HERE ONLY,
# and every refusal below is asserted by the reason sshd logs. The device keeps
# the default — see the runbook: repeated failures lock YOUR address out for a
# while, which matters when you are about to try break-glass.
PENALTY_OPT=()
"$SSHD" -T -f "$R/etc/ssh/sshd_config" -o PidFile="$W/sshd.pid" -C "user=$ME,host=localhost,addr=127.0.0.1" 2>/dev/null \
  | grep -q '^persourcepenalties ' && PENALTY_OPT=(-o PerSourcePenalties=no)
"$SSHD" -f "$R/etc/ssh/sshd_config" -o PidFile="$W/sshd.pid" -o ListenAddress=127.0.0.1 "${PENALTY_OPT[@]}" -E "$W/sshd.log"
for _ in $(seq 50); do [[ -s "$W/sshd.pid" ]] && break; sleep 0.1; done
[[ -s "$W/sshd.pid" ]] || { echo "FATAL: sshd did not start"; cat "$W/sshd.log"; exit 1; }

# host verification: the host key as ga-enroll would publish it (type + base64)
printf '[127.0.0.1]:%s %s\n' "$PORT" "$(awk '{print $1" "$2}' "$R/etc/ssh/keys/ssh_host_ed25519_key.pub")" > "$W/known_hosts"
printf '[127.0.0.1]:%s %s\n' "$PORT" "$(awk '{print $1" "$2}' "$W/keys/rogue.pub")" > "$W/known_hosts_wrong"

touch "$W/client.log"
try() {  # <key> [cert] [known_hosts] -> 0 on login
  local extra=(); [[ -n "${2:-}" ]] && extra+=(-o "CertificateFile=$2")
  ssh -F /dev/null -p "$PORT" -i "$1" "${extra[@]}" -o IdentitiesOnly=yes -o IdentityAgent=none \
      -o BatchMode=yes -o ConnectTimeout=5 -o PasswordAuthentication=no \
      -o StrictHostKeyChecking=yes -o UserKnownHostsFile="${3:-$W/known_hosts}" -o LogLevel=ERROR \
      "$ME@127.0.0.1" 'echo LOGIN-OK' 2>>"$W/client.log" | grep -q LOGIN-OK
}
# A refusal counts only for the RIGHT reason: <why> must show up in what sshd
# (or, for host verification, the client) logged for THIS attempt.
expect() {  # <accept|refuse> <why-regex|-> <desc> <try-args...>
  local want="$1" why="$2" desc="$3"; shift 3; ran=$((ran+1))
  local s0 c0; s0=$(wc -l < "$W/sshd.log"); c0=$(wc -l < "$W/client.log" 2>/dev/null || echo 0)
  if try "$@"; then
    [[ "$want" == accept ]] && ok "ACCEPTED  $desc" || bad "ACCEPTED but should be refused — $desc"; return
  fi
  if [[ "$want" == accept ]]; then bad "REFUSED but should be accepted — $desc"; return; fi
  # sshd's per-connection process may log after the client has already gone.
  local i
  for i in $(seq 30); do
    # Captured first, grepped second: under pipefail, `grep -q` closing the
    # pipe early makes the WRITER fail and the match read as a miss.
    local win; win="$(tail -n +"$((s0+1))" "$W/sshd.log"; tail -n +"$((c0+1))" "$W/client.log" 2>/dev/null)"
    if grep -qE "$why" <<< "$win"
    then ok "refused   $desc  [$why]"; return; fi
    sleep 0.1
  done
  bad "refused for the WRONG reason (want /$why/) — $desc"; [[ -n "${GA_DRYRUN_DEBUG:-}" ]] && { echo "s0=$s0"; tail -n +"$((s0+1))" "$W/sshd.log" | head -5; }
}
sign() {  # <ca-key> <out-name> <args...>  (LIVE sign script, file CA allowed for the dry run)
  local ca="$1" name="$2"; shift 2
  cp "$W/keys/op" "$W/$name"; cp "$W/keys/op.pub" "$W/$name.pub"
  if (( TOKEN )) && [[ "$ca" == "$W/keys/ca_a" ]]; then
    echo "  [token] signing $name — enter the PIV PIN and touch the key when it blinks"
    GA_SSH_CA_PUB="$W/keys/ca_a.pub" GA_SSH_PKCS11="$GA_DRYRUN_PKCS11" GA_CERT_LEDGER="$W/ledger" \
    GA_CERT_SERIAL_STATE="$W/serial" GA_CERT_IDENTITY=dryrun-operator "$SIGN" "$@" "$W/$name.pub" > "$W/sign-$name.out" 2>&1
    return
  fi
  GA_SSH_CA_KEY="$ca" GA_SSH_ALLOW_FILE_CA=1 GA_CERT_LEDGER="$W/ledger" GA_CERT_SERIAL_STATE="$W/serial" \
  GA_CERT_IDENTITY=dryrun-operator "$SIGN" "$@" "$W/$name.pub" > "$W/sign-$name.out" 2>&1
}
raw() {  # <ca-key> <out-name> <principals> <validity>  (bypasses the script's refusals)
  local ca="$1"; (( TOKEN )) && [[ "$ca" == "$W/keys/ca_a" ]] && ca="$W/keys/ca_b"; set -- "$ca" "${@:2}"
  cp "$W/keys/op" "$W/$2"; cp "$W/keys/op.pub" "$W/$2.pub"
  ssh-keygen -q -s "$1" -I raw -n "$3" -V "$4" "$W/$2.pub" 2>/dev/null
}

echo "── 3b. the image holds on an OTA-updated overlay (config level) ──"
EFF="$("$SSHD" -T -f "$R/etc/ssh/sshd_config" -o PidFile="$W/sshd.pid" -C "user=$ME,host=localhost,addr=127.0.0.1" 2>/dev/null)"
ran=$((ran+1)); akf_first="$(sed -nE 's/^authorizedkeysfile ([^ ]+).*/\1/p' <<< "$EFF")"
[[ "$akf_first" == "$R/usr/share/ga-ssh/authorized_keys" ]] \
  && ok "sshd -T: the FIRST AuthorizedKeysFile is the baked break-glass file" \
  || bad "sshd -T: first AuthorizedKeysFile is '${akf_first/#$W/<tmp>}', want the baked /usr/share/ga-ssh/authorized_keys"
ran=$((ran+1)); grep -qx "revokedkeys $R/etc/ssh/ga_revoked_keys" <<< "$EFF" \
  && ok "sshd -T: RevokedKeys is the baked /etc/ssh/ga_revoked_keys" \
  || bad "sshd -T: RevokedKeys is '$(sed -n 's/^revokedkeys //p' <<< "$EFF" | sed "s#$W#<tmp>#g")', want /etc/ssh/ga_revoked_keys"
ran=$((ran+1)); ssh-keygen -lf "$T/etc/ssh/ga_revoked_keys" 2>/dev/null | grep -qF "$LEGACY_FP" \
  && ok "baked revocation list holds the pre-cut fleet key ($LEGACY_FP)" \
  || bad "baked revocation list does not hold the pre-cut fleet key"
# sshd starts on the file it reads: the unit drop-in's condition and the first
# AuthorizedKeysFile must name the same file (two sources, one truth).
UNIT_DROPIN="$T/usr/lib/systemd/system/sshd.service.d/zz-ga-cert-plane.conf"
ran=$((ran+1))
if [[ -r "$UNIT_DROPIN" ]] && grep -qx 'ConditionFileNotEmpty=' "$UNIT_DROPIN" \
   && [[ "$(sed -nE 's/^ConditionFileNotEmpty=(.+)$/\1/p' "$UNIT_DROPIN")" == "$(sed -nE 's/^AuthorizedKeysFile ([^ ]+).*/\1/p' "$T/etc/ssh/sshd_config.d/50-ga-cert-plane.conf")" ]] \
   && [[ "$(printf '%s\n' hassos.conf "${UNIT_DROPIN##*/}" | LC_ALL=C sort | tail -1)" == "${UNIT_DROPIN##*/}" ]]
then ok "sshd unit gates on the first AuthorizedKeysFile (condition reset, drop-in sorts after hassos.conf)"
else bad "sshd unit condition does not name the file sshd reads first ($UNIT_DROPIN)"; fi
# The LIVE posture sensor, on the effective config of this run: 'ca', and only
# BECAUSE of the revocation — the same config without it must read 'shared'.
POSTURE="$OVL/usr/libexec/ga-ssh-posture"
ran=$((ran+1)); got="$(GA_SSHD_CONFIG="$R/etc/ssh/sshd_config" GA_SSH_ROOT_HOME="$R/root" sh "$POSTURE" 2>/dev/null)"
[[ "$got" == ca ]] && ok "ga-ssh-posture on the OTA-updated overlay: ca" || bad "ga-ssh-posture on the OTA-updated overlay: '$got', want ca"
mkdir -p "$W/norev/sshd_config.d"
grep -v '^RevokedKeys' "$R/etc/ssh/sshd_config.d/50-ga-cert-plane.conf" > "$W/norev/sshd_config.d/50-ga-cert-plane.conf"
sed "s#^Include .*#Include $W/norev/sshd_config.d/*.conf#" "$R/etc/ssh/sshd_config" > "$W/norev/sshd_config"
ran=$((ran+1)); got="$(GA_SSHD_CONFIG="$W/norev/sshd_config" GA_SSH_ROOT_HOME="$R/root" sh "$POSTURE" 2>/dev/null)"
[[ "$got" == shared ]] && ok "control: the same device WITHOUT RevokedKeys reads shared" || bad "control without RevokedKeys: '$got', want shared"

echo "── 4. certificates from the LIVE sign script ──"
sign "$W/keys/ca_a" c_label "$LABEL"                           ; sed -n '/Principals/,+2p' "$W/sign-c_label.out" | sed 's/^/  /'
sign "$W/keys/ca_b" c_anchor --anchor "$ANCHOR" --no-label "$LABEL"
sign "$W/keys/ca_a" c_both --anchor "$ANCHOR" "$LABEL"
sign "$W/keys/ca_a" c_other "$OTHER"
raw  "$W/keys/rogue" c_rogue "$LABEL" "+1h"
raw  "$W/keys/ca_a" c_expired "$LABEL" "-2h:-1h"
raw  "$W/keys/ca_a" c_kibu "kibu" "+1h"
raw  "$W/keys/ca_a" c_star "*" "+1h"

echo "── 5. sign-script refusals ──"
for bad_args in "kibu" "*" "KIB-SON-31" "--anchor kibu $LABEL"; do
  ran=$((ran+1)); cp "$W/keys/op.pub" "$W/x.pub"
  # shellcheck disable=SC2086
  if GA_SSH_CA_KEY="$W/keys/ca_b" GA_SSH_ALLOW_FILE_CA=1 GA_CERT_LEDGER="$W/l2" GA_CERT_SERIAL_STATE="$W/s2" "$SIGN" $bad_args "$W/x.pub" >/dev/null 2>&1
  then bad "sign script signed for '$bad_args'"; else ok "sign script refuses '$bad_args'"; fi
done
ran=$((ran+1)); if GA_SSH_CA_KEY="$W/keys/ca_b" GA_CERT_LEDGER="$W/l2" "$SIGN" "$LABEL" "$W/x.pub" >/dev/null 2>&1; then bad "file CA accepted without the test switch"; else ok "sign script refuses a file-backed CA without GA_SSH_ALLOW_FILE_CA=1"; fi
ran=$((ran+1)); if GA_CERT_VALIDITY=+48h GA_SSH_CA_KEY="$W/keys/ca_b" GA_SSH_ALLOW_FILE_CA=1 GA_CERT_LEDGER="$W/l2" GA_CERT_SERIAL_STATE="$W/s2" "$SIGN" "$LABEL" "$W/x.pub" >/dev/null 2>&1; then bad "48 h certificate issued"; else ok "sign script refuses validity +48h"; fi

echo "── 6. accept / refuse against the running sshd ──"
expect accept - "cert by CA A (PIV-shaped P-256), principal = label $LABEL"   "$W/c_label"   "$W/c_label-cert.pub"
expect accept - "cert by CA B, principal = anchor only (fresh device before identity)" "$W/c_anchor" "$W/c_anchor-cert.pub"
expect accept - "cert naming anchor + label (what the runbook issues)"       "$W/c_both"    "$W/c_both-cert.pub"
expect refuse 'not contain an authorized principal' "cert for ANOTHER device ($OTHER)" "$W/c_other" "$W/c_other-cert.pub"
expect refuse "Failed publickey.*ID raw.*CA ED25519 $(ssh-keygen -lf "$W/keys/rogue.pub" | awk '{print $2}' | sed 's/[+.]/\\&/g')" "cert signed by a CA the image does not trust" "$W/c_rogue" "$W/c_rogue-cert.pub"
expect refuse 'Certificate invalid: expired' "expired cert"                 "$W/c_expired" "$W/c_expired-cert.pub"
expect refuse 'not contain an authorized principal' "cert naming 'kibu' (the name every device ships with)" "$W/c_kibu" "$W/c_kibu-cert.pub"
expect refuse 'not contain an authorized principal' "cert naming '*'"       "$W/c_star"    "$W/c_star-cert.pub"
expect refuse 'Failed publickey for .* ED25519 SHA256' "operator key WITHOUT its certificate" "$W/keys/op"
expect refuse 'Failed publickey for .* ED25519 SHA256' "a plain static key (what the shared plane used)" "$W/keys/plain"
expect accept - "BREAK-GLASS plain key (paper) — works from the baked file; the overlay does not hold it" "$W/keys/bg"
expect refuse 'key .* revoked by file' "a key the overlay authorises but the baked revocation list holds" "$W/keys/revoked"
expect accept - "a key the overlay authorises and nothing revokes (overlay entries stay valid)" "$W/keys/extra"
expect refuse 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED' "valid cert, but the host key does NOT match the register (MITM)" "$W/c_label" "$W/c_label-cert.pub" "$W/known_hosts_wrong"

echo "── 7. the operator-side verify script (what runs against the canary) goes green AND red ──"
V="$ROOT/scripts/ops/ga-ssh-cert-plane-verify.sh"
ran=$((ran+1))
if GA_VERIFY_PENALTY_WAIT=0 "$V" --host 127.0.0.1 --port "$PORT" --user "$ME" --cert "$W/c_both" --other "$W/c_other" \
     --shared "$W/keys/plain" --breakglass "$W/keys/bg" --known-hosts "$W/known_hosts" > "$W/verify.out" 2>&1
then ok "verify script: all cases verified on the correct image"; else bad "verify script failed on the correct image: $(tail -3 "$W/verify.out")"; fi
ran=$((ran+1))
if GA_VERIFY_PENALTY_WAIT=0 "$V" --host 127.0.0.1 --port "$PORT" --user "$ME" --cert "$W/c_other" --other "$W/c_both" \
     --shared "$W/keys/plain" --breakglass "$W/keys/bg" --known-hosts "$W/known_hosts" > "$W/verify.out" 2>&1
then bad "verify script passed with the certificates swapped"; else ok "verify script goes red when the 'own' cert is for another device"; fi
ran=$((ran+1))
rc=0; GA_VERIFY_PENALTY_WAIT=0 "$V" --host 127.0.0.1 --port "$PORT" --user "$ME" --cert "$W/c_both" --other "$W/c_other" > "$W/verify.out" 2>&1 || rc=$?
[[ $rc == 2 ]] && ok "verify script exits 2 (UNVERIFIED) when break-glass/shared/known_hosts are not supplied" || bad "verify script rc=$rc without optional inputs, want 2"

# A revocation list sshd cannot parse makes it refuse EVERY public key,
# certificates and break-glass included. Nothing above would name that cause.
ran=$((ran+1))
if grep -q 'in revoked keys file' "$W/sshd.log"; then
  bad "sshd could not read the revocation list: $(grep -m1 'in revoked keys file' "$W/sshd.log" | sed "s#$W#<tmp>#g")"
else ok "sshd read the revocation list without an error on every attempt"; fi

echo "── 8. what the device log records (LogLevel VERBOSE: key ID + serial) ──"
grep -E 'Accepted certificate ID|Accepted publickey' "$W/sshd.log" | sed -E 's/^.*(Accepted)/  \1/' | head -5
ran=$((ran+1)); grep -q 'Accepted certificate ID "dryrun-operator@ga"' "$W/sshd.log" && ok "sshd log names the certificate holder" || bad "sshd log does not name the certificate holder"
(( VERBOSE )) && { echo "── sshd.log ──"; sed "s#$W#<tmp>#g" "$W/sshd.log"; }

echo
if (( ran < 31 )); then echo "${RED}FAIL${NC}  only $ran cases ran — expected at least 31"; exit 1; fi
if (( fails > 0 )); then echo "${RED}${fails} of ${ran} case(s) failed${NC}"; sed "s#$W#<tmp>#g" "$W/sshd.log" | tail -30; exit 1; fi
echo "${GRN}all ${ran} cases passed${NC}"
