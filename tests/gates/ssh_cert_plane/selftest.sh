#!/usr/bin/env bash
# =============================================================================
# selftest.sh — the bake-time switch onto the certificate plane (ADR-0019 s2)
# =============================================================================
# Drives the LIVE post-build hook (post-build.d/87-ssh-cert-plane.sh) against
# fixture target trees and fixture secrets, then asks the LIVE build gate
# (run_build_tests.sh) what it thinks of the result. Two claims, both ways:
#
#   * a BOSv1.4.0+ image can NOT leave the build without a real CA public key
#     and a break-glass key — the hook refuses, and the preflight refuses;
#   * a pre-cut image is NOT moved onto the certificate plane, even when the
#     CA public key is sitting in the secrets mount.
#
# The real CA does not exist yet (the key ceremony is what makes it); every key
# here is a throwaway generated per run. Offline, no build, ~3 seconds.
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
HOOK="$ROOT/buildroot-ihost/board/sonoff/ihost/post-build.d/87-ssh-cert-plane.sh"
RUNNER="$ROOT/tests/ga_tests/run_build_tests.sh"
OVL="$ROOT/buildroot-external/rootfs-overlay"
LEGACY_KEY="$ROOT/tests/gates/ssh_posture/legacy-fleet-key.pub"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
fails=0; ran=0
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }
for f in "$HOOK" "$RUNNER" "$OVL/etc/ssh/sshd_config" "$LEGACY_KEY"; do
  [[ -r "$f" ]] || { echo "FATAL: $f missing"; exit 1; }
done
command -v ssh-keygen >/dev/null || { echo "FATAL: ssh-keygen required"; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
ssh-keygen -q -t ecdsa -b 256 -N '' -C yk-a -f "$W/ca_a"
ssh-keygen -q -t ed25519      -N '' -C yk-b -f "$W/ca_b"
ssh-keygen -q -t ed25519      -N '' -C bg   -f "$W/bg"

# secrets <name> <ca-content|-> <bg-content|->  -> dir
secrets() {
  local d="$W/sec-$1"; mkdir -p "$d/ssh"
  [[ "$2" != "-" ]] && printf '%s' "$2" > "$d/ssh/ga_user_ca.pub"
  [[ "$3" != "-" ]] && printf '%s' "$3" > "$d/ssh/ga_breakglass.pub"
  printf '%s' "$d"
}
# target <name> <release>  -> dir (build dir with target/, shaped like today's image)
target() {
  local d="$W/img-$1" t; t="$d/target"; mkdir -p "$t/etc/ssh" "$t/usr/share/ga-ssh" \
    "$t/usr/lib/systemd/system/sshd.service.d" "$t/usr/libexec" "$t/usr/sbin" "$t/usr/bin"
  printf '%s\n' "$2" > "$t/etc/ga-release"
  cp "$OVL/etc/ssh/sshd_config" "$t/etc/ssh/sshd_config"
  cp "$LEGACY_KEY" "$t/usr/share/ga-ssh/authorized_keys"
  cp "$OVL/usr/lib/systemd/system/sshd.service.d/hassos.conf" "$t/usr/lib/systemd/system/sshd.service.d/"
  cp "$OVL/usr/lib/systemd/system/etc-ssh-principals.mount" "$t/usr/lib/systemd/system/"
  for x in ga-sshd-prepare ga-ssh-principals ga-ssh-principal-label; do cp "$OVL/usr/libexec/$x" "$t/usr/libexec/"; done
  printf '%s' "$d"
}
run_hook() { GA_SECRETS_DIR="$1" bash "$HOOK" "$2/target" >"$W/hook.out" 2>&1; }
verdict() {
  local line; line="$(bash "$RUNNER" "$1" 2>&1 | grep -E "  (PASS|FAIL)  $2:" | head -1)"
  case "$line" in *"  PASS  "*) echo PASS ;; *"  FAIL  "*) echo FAIL ;; *) echo ABSENT ;; esac
}
expect_gate() { local got; got="$(verdict "$2" "$3")"; ran=$((ran+1))
  [[ "$got" == "$1" ]] && ok "$3 $1 — $4" || bad "$3 → got $got, want $1 — $4"; }
# A refusal only counts for the RIGHT reason: <why> must appear in the hook's
# output. (Found the hard way: without it, a key with no trailing newline was
# "refused" for an unrelated reason and the case went green.)
expect_hook() {  # <want: refuse|accept> <secrets> <img> <desc> [<why>]
  ran=$((ran+1)); local rc=0; run_hook "$2" "$3" || rc=$?
  if [[ "$1" == refuse ]]; then
    if (( rc == 0 )); then bad "hook ACCEPTED — $4"
    elif [[ -n "${5:-}" ]] && ! grep -q -- "$5" "$W/hook.out"; then bad "hook refused for the WRONG reason — $4: $(tail -1 "$W/hook.out")"
    else ok "hook refused — $4"; fi
  else
    (( rc == 0 )) && ok "hook accepted — $4" || bad "hook refused — $4: $(tail -1 "$W/hook.out")"
  fi
}

CA_A="$(cat "$W/ca_a.pub")"; CA_B="$(cat "$W/ca_b.pub")"; BG="$(cat "$W/bg.pub")"
GOOD="$(secrets good "$CA_A"$'\n'"$CA_B"$'\n' "$BG"$'\n')"

echo "── a 1.4.0 image must NOT leave the build without real keys ──"
expect_hook refuse "$(secrets none - -)"                     "$(target a BOSv1.4.0-rc1)" "no secrets at all" "user CA public key not found"
expect_hook refuse "$(secrets noca - "$BG")"                 "$(target b BOSv1.4.0-rc1)" "break-glass but no CA" "user CA public key not found"
expect_hook refuse "$(secrets nobg "$CA_A" -)"               "$(target c BOSv1.4.0-rc1)" "CA but no break-glass" "break-glass public key not found"
expect_hook refuse "$(secrets ph "ssh-ed25519 AAAAPLACEHOLDER-REPLACE-AT-KEY-CEREMONY x" "$BG")" "$(target d BOSv1.4.0-rc1)" "CA is the placeholder" "still the placeholder"
expect_hook refuse "$(secrets three "$CA_A"$'\n'"$CA_B"$'\n'"$BG" "$BG")" "$(target e BOSv1.4.0-rc1)" "three CA keys" "must hold 1..2"
expect_hook refuse "$(secrets same "$CA_A" "$CA_A")"         "$(target f BOSv1.4.0-rc1)" "break-glass key is also a CA key" "also listed as a CA key"
expect_hook refuse "$(secrets bg2 "$CA_A" "$BG"$'\n'"$CA_B")" "$(target g BOSv1.4.0-rc1)" "two break-glass keys" "must hold 1..1"
expect_hook refuse "$(secrets garbage "not a key" "$BG")"    "$(target h BOSv1.4.0-rc1)" "CA file is not a key" "not an ed25519/ECDSA"
expect_hook refuse "$(secrets rsa "$(ssh-keygen -q -t rsa -b 2048 -N '' -f "$W/rsa" && cat "$W/rsa.pub")" "$BG")" "$(target i BOSv1.4.0-rc1)" "RSA CA (not accepted for the user CA)" "not an ed25519/ECDSA"
ran=$((ran+1)); if GA_SECRETS_DIR="$W/sec-none" bash "$HOOK" --check BOSv1.4.0-rc1 >/dev/null 2>&1; then bad "preflight passed 1.4.0 with no keys"; else ok "preflight refuses 1.4.0 with no keys"; fi
ran=$((ran+1)); if GA_SECRETS_DIR="$W/sec-none" bash "$HOOK" --check BOSv1.3.0-rc51 >/dev/null 2>&1; then ok "preflight lets 1.3.0 through with no keys"; else bad "preflight blocked a pre-cut build"; fi
ran=$((ran+1)); if GA_SECRETS_DIR="$GOOD" bash "$HOOK" --check BOSv1.4.0-rc1 >/dev/null 2>&1; then ok "preflight passes 1.4.0 with good keys"; else bad "preflight refused good keys"; fi

echo "── a pre-cut image must stay on the shared plane, keys or no keys ──"
d="$(target pre BOSv1.3.0-rc51)"
mkdir -p "$d/target/etc/ssh/sshd_config.d"; echo stale > "$d/target/etc/ssh/ga_user_ca.pub"; echo stale > "$d/target/etc/ssh/sshd_config.d/50-ga-cert-plane.conf"
echo stale > "$d/target/etc/ssh/ga_revoked_keys"; echo stale > "$d/target/usr/lib/systemd/system/sshd.service.d/zz-ga-cert-plane.conf"
expect_hook accept "$GOOD" "$d" "BOSv1.3.0-rc51 with CA keys present in the mount"
ran=$((ran+1)); if [[ -e "$d/target/etc/ssh/ga_user_ca.pub" || -e "$d/target/etc/ssh/sshd_config.d/50-ga-cert-plane.conf" ]]; then bad "pre-cut image carries CA files"; else ok "pre-cut image: no CA pub, no cert drop-in (stale leftovers removed)"; fi
ran=$((ran+1)); if [[ -e "$d/target/etc/ssh/ga_revoked_keys" || -e "$d/target/usr/lib/systemd/system/sshd.service.d/zz-ga-cert-plane.conf" ]]; then bad "pre-cut image carries the revocation list or the sshd unit drop-in"; else ok "pre-cut image: no revocation list, no sshd unit drop-in (stale leftovers removed)"; fi
ran=$((ran+1)); if cmp -s "$LEGACY_KEY" "$d/target/usr/share/ga-ssh/authorized_keys"; then ok "pre-cut image: authorized_keys untouched"; else bad "pre-cut authorized_keys changed"; fi
expect_gate PASS "$d" SSH-06 "pre-cut image after the hook — marker and content say shared"

echo "── the 1.4.0 image the hook produces must pass the live gate ──"
d="$(target cut BOSv1.4.0-rc1)"
expect_hook accept "$GOOD" "$d" "BOSv1.4.0-rc1 with two CA keys + break-glass"
ran=$((ran+1)); [[ "$(grep -c . "$d/target/etc/ssh/ga_user_ca.pub")" == 2 ]] && ok "both CA keys baked" || bad "CA file does not hold both keys"
ran=$((ran+1)); if [[ "$(awk '{print $1" "$2}' "$d/target/usr/share/ga-ssh/authorized_keys")" == "$(awk '{print $1" "$2}' "$W/bg.pub")" ]]; then ok "authorized_keys = break-glass only"; else bad "authorized_keys is not exactly the break-glass key"; fi
for c in SSH-05 SSH-06 SSH-07 SSH-09 SSH-10; do expect_gate PASS "$d" "$c" "hook output"; done
ran=$((ran+1)); if ssh-keygen -lf "$d/target/etc/ssh/ga_revoked_keys" 2>/dev/null | grep -qF "$(ssh-keygen -lf "$LEGACY_KEY" | awk '{print $2}')"; then ok "revocation list baked with the pre-cut fleet key"; else bad "baked revocation list lacks the pre-cut fleet key"; fi

echo "── an image that would NOT hold on an OTA-updated overlay must fail SSH-10 ──"
# mutate <name> <sed-expression> <file under target/>  -> dir (a copy of the good hook output)
mutate() { local m="$W/mut-$1"; rm -rf "$m"; cp -a "$d" "$m"; sed -i "$2" "$m/target/$3"; printf '%s' "$m"; }
DI=etc/ssh/sshd_config.d/50-ga-cert-plane.conf
expect_gate FAIL "$(mutate no-revoked '/^RevokedKeys/d' "$DI")" SSH-10 "drop-in without RevokedKeys"
expect_gate FAIL "$(mutate overlay-first 's#^AuthorizedKeysFile .*#AuthorizedKeysFile /root/.ssh/authorized_keys /usr/share/ga-ssh/authorized_keys#' "$DI")" SSH-10 "overlay file read first"
expect_gate FAIL "$(mutate no-akf '/^AuthorizedKeysFile/d' "$DI")" SSH-10 "no AuthorizedKeysFile in the drop-in (main file's overlay path wins)"
expect_gate FAIL "$(mutate empty-list 's/.*//' etc/ssh/ga_revoked_keys)" SSH-10 "revocation list without any key"
expect_gate FAIL "$(mutate cond-overlay 's#^ConditionFileNotEmpty=/usr/share.*#ConditionFileNotEmpty=/root/.ssh/authorized_keys#' usr/lib/systemd/system/sshd.service.d/zz-ga-cert-plane.conf)" SSH-10 "sshd unit still gated on the overlay file"
m="$(mutate no-unit-dropin 's/x/x/' etc/ga-release)"; rm -f "$m/target/usr/lib/systemd/system/sshd.service.d/zz-ga-cert-plane.conf"
expect_gate FAIL "$m" SSH-10 "sshd unit drop-in missing"
m="$(mutate bg-revoked 's/x/x/' etc/ga-release)"; awk '{print $1" "$2}' "$W/bg.pub" >> "$m/target/etc/ssh/ga_revoked_keys"
expect_gate FAIL "$m" SSH-10 "break-glass key on the revocation list"

echo "── the hook refuses a revocation list that has lost the pre-cut key ──"
# The LIVE hook, copied verbatim into a board-shaped dir so its committed
# revocation list (../ssh-revoked-keys) can be swapped for a fixture.
REVOKED_LIVE="$ROOT/buildroot-ihost/board/sonoff/ihost/ssh-revoked-keys"
[[ -s "$REVOKED_LIVE" ]] || { echo "FATAL: $REVOKED_LIVE missing"; exit 1; }
hook_with_list() {  # <name> <list-content|-> -> runs the hook copy on a fresh 1.4 target; rc
  local b="$W/board-$1"; mkdir -p "$b/post-build.d"; cp "$HOOK" "$b/post-build.d/"
  [[ "$2" != "-" ]] && printf '%s' "$2" > "$b/ssh-revoked-keys"
  GA_SECRETS_DIR="$GOOD" bash "$b/post-build.d/${HOOK##*/}" "$(target "rl-$1" BOSv1.4.0-rc1)/target" >"$W/hook.out" 2>&1
}
expect_list() {  # <want: refuse|accept> <name> <content|-> <why> <desc>
  ran=$((ran+1)); local rc=0; hook_with_list "$2" "$3" || rc=$?
  if [[ "$1" == refuse ]]; then
    if (( rc == 0 )); then bad "hook ACCEPTED — $5"
    elif ! grep -q -- "$4" "$W/hook.out"; then bad "hook refused for the WRONG reason — $5: $(tail -1 "$W/hook.out")"
    else ok "hook refused — $5"; fi
  else (( rc == 0 )) && ok "hook accepted — $5" || bad "hook refused — $5: $(tail -1 "$W/hook.out")"; fi
}
expect_list refuse missing - "revocation list not found" "no revocation list next to the hook"
expect_list refuse other "$(cat "$W/ca_b.pub")"$'\n' "does not hold the pre-cut fleet key" "revocation list without the pre-cut key"
expect_list refuse garbage "not a key"$'\n' "not an OpenSSH public key line" "revocation list with a non-key line"
expect_list refuse bg "$(cat "$LEGACY_KEY")"$'\n'"$(cat "$W/bg.pub")"$'\n' "break-glass key is on the revocation list" "break-glass key on the revocation list"
expect_list accept live "$(cat "$REVOKED_LIVE")"$'\n' "" "the committed revocation list"
ran=$((ran+1)); if GA_SECRETS_DIR="$GOOD" bash "$W/board-other/post-build.d/${HOOK##*/}" --check BOSv1.4.0-rc1 >/dev/null 2>&1; then bad "preflight passed a revocation list without the pre-cut key"; else ok "preflight refuses a revocation list without the pre-cut key"; fi
d2="$(target rc2 BOSv1.4.1-dev3)"; run_hook "$GOOD" "$d2" >/dev/null 2>&1
expect_gate PASS "$d2" SSH-06 "a later -devN build is on the certificate plane too (suffix never matters)"

echo
if (( ran < 40 )); then echo "${RED}FAIL${NC}  only $ran cases ran — expected at least 40"; exit 1; fi
if (( fails > 0 )); then echo "${RED}${fails} of ${ran} case(s) failed${NC}"; exit 1; fi
echo "${GRN}all ${ran} cases passed${NC}"
