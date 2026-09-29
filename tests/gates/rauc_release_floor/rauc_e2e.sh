#!/usr/bin/env bash
# =============================================================================
# rauc_e2e.sh — a REAL RAUC runs the LIVE release-floor handler
# =============================================================================
# selftest.sh proves the handler's verdicts by calling it directly. This proves
# the seam: that RAUC itself, configured through a [handlers] pre-install= key,
# calls the handler for `rauc install`, aborts the install when it refuses,
# writes nothing to the target slot, and completes when it allows. It also
# records the claim the override design rests on — `rauc install` runs the
# handler in the rauc SERVICE's environment, so an environment variable on the
# caller's command line never reaches it.
#
# Sandbox: throwaway CA + signing key, a two-slot system with raw slot FILES
# and bootloader=noop, `rauc service` on a private D-Bus session bus. The
# handler is the live file, reached through a one-line shim that only adds
# the fixture root argument (RAUC calls handlers without arguments).
#
# Needs root (loop + dm-verity mounts): run as root or with passwordless sudo.
#   RAUC=<path to rauc> ./rauc_e2e.sh      (default: rauc on PATH)
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
HANDLER="$ROOT/buildroot-external/rootfs-overlay/usr/lib/rauc/ga-release-floor"
MF_TPL="$ROOT/buildroot-external/ota/manifest.raucm.gtpl"
SC_TPL="$ROOT/buildroot-external/ota/system.conf.gtpl"
RAUC="${RAUC:-$(command -v rauc || true)}"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=''; GRN=''; NC=''; }
fails=0; ran=0
ok()  { ran=$((ran+1)); printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; }

[[ -x "$HANDLER" ]] || { echo "FATAL: $HANDLER missing or not executable"; exit 1; }
[[ -n "$RAUC" && -x "$RAUC" ]] || { echo "FATAL: no rauc binary (set RAUC=)"; exit 1; }
SUDO=""; [[ "$(id -u)" == 0 ]] || SUDO="sudo -n"
$SUDO true 2>/dev/null || { echo "FATAL: needs root or passwordless sudo"; exit 1; }
command -v dbus-run-session >/dev/null || { echo "FATAL: dbus-run-session missing"; exit 1; }
echo "=== release floor through a real RAUC: $("$RAUC" --version) ==="

W="$(mktemp -d)"; trap '$SUDO rm -rf "$W"' EXIT
cd "$W" || exit 1
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 \
  -subj "/CN=floor-e2e-ca" -addext basicConstraints=critical,CA:TRUE >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout sign.key -out sign.csr -subj "/CN=floor-e2e-sign" >/dev/null 2>&1
openssl x509 -req -in sign.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out sign.pem -days 2 >/dev/null 2>&1
[[ -s sign.pem ]] || { echo "FATAL: could not mint throwaway certificates"; exit 1; }

# bundle <name> <release|->  (content: one raw rootfs image with a marker)
bundle() {
  local c="$W/c-$1"; mkdir -p "$c"
  { printf '[update]\ncompatible=ga-floor-e2e\nversion=16.3.1.9\n'
    [[ "$2" != "-" ]] && printf '\n[meta.ga]\nrelease=%s\n' "$2"
    printf '\n[bundle]\nformat=verity\n\n[image.rootfs]\nfilename=rootfs.img\n'
  } > "$c/manifest.raucm"
  # Random filler: a squashfs of zeros compresses below RAUC's minimum size.
  { printf 'PAYLOAD-%s\n' "$1"; head -c 65536 /dev/urandom; } > "$c/rootfs.img"
  "$RAUC" bundle --cert=sign.pem --key=sign.key --keyring=ca.pem "$c" "$W/$1.raucb" >/dev/null 2>&1 \
    || { echo "FATAL: rauc bundle failed for $1"; exit 1; }
}

mkdir -p root/etc root/run mnt
printf 'BOSv1.4.0-rc1\n' > root/etc/ga-release
truncate -s 128K slotA.img slotB.img
cat > shim <<EOF
#!/bin/sh
env > "$W/handler-env.txt"
exec sh "$HANDLER" "$W/root"
EOF
chmod +x shim
cat > system.conf <<EOF
[system]
compatible=ga-floor-e2e
bootloader=noop
mountprefix=$W/mnt
statusfile=$W/rauc.db

[handlers]
pre-install=$W/shim

[keyring]
path=$W/ca.pem

[slot.rootfs.0]
device=$W/slotA.img
type=raw
bootname=A

[slot.rootfs.1]
device=$W/slotB.img
type=raw
bootname=B
EOF

# The system as every image before the floor has it: no [handlers] section.
sed '/^\[handlers\]/,/^$/d' system.conf > system-prefloor.conf

bundle older   BOSv1.3.0-rc55
bundle nometa  -
bundle newer   BOSv1.4.0-rc2
bundle final   BOSv1.4.0

# install <bundle> [VAR=value...]  -> rc ; output in $W/install.out
# The VAR=value pairs go on the `rauc install` CLIENT only, as an operator
# would type them; the service is started without them.
cat > "$W/run-install.sh" <<'EOS'
#!/bin/sh
# $1 rauc  $2 workdir  $3 system.conf  $4 bundle  $5.. client env — private session bus
export DBUS_STARTER_BUS_TYPE=session   # dbus-run-session does not keep it
"$1" service --conf="$2/$3" --override-boot-slot=A >"$2/service.log" 2>&1 &
svc=$!
i=0; until "$1" status >/dev/null 2>&1 || [ $i -ge 20 ]; do i=$((i+1)); sleep 0.5; done
r="$1" d="$2" b="$4"; shift 4
env "$@" "$r" install "$d/$b.raucb"; rc=$?
set -- "$r" "$d"
kill $svc 2>/dev/null; wait $svc 2>/dev/null
[ $rc = 0 ] || sed 's/^/service: /' "$2/service.log"
exit $rc
EOS
install() {
  local b="$1"; shift
  $SUDO dbus-run-session -- \
    sh "$W/run-install.sh" "$RAUC" "$W" "${CONF:-system.conf}" "$b" "$@" >"$W/install.out" 2>&1
  echo $?
}
slot_has() { grep -aq "PAYLOAD-$1" "$W/slotB.img"; }

# TRANSITION: the first bundle that carries [meta.ga] must install on a device
# whose image predates the floor. RAUC ignores meta.<label> groups it has no
# use for (since 1.8), and the pre-floor system.conf has no handler.
rc="$(CONF=system-prefloor.conf install newer)"
if [[ "$rc" == 0 ]] && slot_has newer; then ok "pre-floor system (no handler) installs a bundle carrying [meta.ga]"
else bad "pre-floor system refused a meta-carrying bundle: rc=$rc: $(tail -3 "$W/install.out" | tr '\n' ' ')"; fi
: > slotB.img; truncate -s 128K slotB.img

rc="$(install older GA_ALLOW_OLDER=1 FORCE=1)"
if [[ "$rc" != 0 ]] && grep -q 'Pre-install handler error' "$W/install.out" "$W/service.log" && ! slot_has older; then
  ok "older bundle (BOSv1.3.0-rc55) → RAUC aborts with 'Pre-install handler error', slot untouched"
else bad "older bundle: rc=$rc, slot written=$(slot_has older && echo yes || echo no): $(tail -3 "$W/install.out" | tr '\n' ' ')"; fi
if [[ -s "$W/handler-env.txt" ]] && ! grep -q '^GA_ALLOW_OLDER=' "$W/handler-env.txt" \
   && grep -q '^RAUC_BUNDLE_MOUNT_POINT=' "$W/handler-env.txt"; then
  ok "handler runs in the rauc service's environment: RAUC_BUNDLE_MOUNT_POINT set, the caller's GA_ALLOW_OLDER absent"
else bad "handler environment not as claimed: $(grep -E '^(GA_ALLOW_OLDER|RAUC_BUNDLE_MOUNT_POINT)=' "$W/handler-env.txt" 2>/dev/null | tr '\n' ' ')"; fi
# Informational only: RAUC exports manifest meta to handlers as RAUC_META_* in
# 1.13 (the image's version) but not in 1.11.3 (the CI runner's). The handler
# does not depend on it — it reads manifest.raucm from the mounted bundle.
if grep -q '^RAUC_META_GA_RELEASE=BOSv1.3.0-rc55$' "$W/handler-env.txt"; then
  echo "  info  this RAUC exports RAUC_META_GA_RELEASE to handlers"
else echo "  info  this RAUC does not export RAUC_META_* to handlers (the handler reads the manifest file)"; fi

rc="$(install nometa)"
if [[ "$rc" != 0 ]] && grep -q 'Pre-install handler error' "$W/install.out" "$W/service.log" && ! slot_has nometa; then
  ok "bundle without [meta.ga] → aborted, slot untouched"
else bad "bundle without meta: rc=$rc: $(tail -3 "$W/install.out" | tr '\n' ' ')"; fi

rc="$(install newer)"
if [[ "$rc" == 0 ]] && slot_has newer; then ok "BOSv1.4.0-rc2 over BOSv1.4.0-rc1 → installed into the other slot"
else bad "newer bundle not installed: rc=$rc: $(tail -3 "$W/install.out" | tr '\n' ' ')"; fi

rc="$(install final)"
if [[ "$rc" == 0 ]] && slot_has final; then ok "BOSv1.4.0 over BOSv1.4.0-rc1 → installed"
else bad "final not installed: rc=$rc: $(tail -3 "$W/install.out" | tr '\n' ' ')"; fi

# The documented override token, as ga-rauc-install-older writes it (root, 0700).
$SUDO mkdir -p "$W/root/run/ga-rauc-floor"; $SUDO chmod 700 "$W/root/run/ga-rauc-floor"
printf 'BOSv1.3.0-rc55\n' | $SUDO tee "$W/root/run/ga-rauc-floor/allow-older" >/dev/null
rc="$(install older)"
if [[ "$rc" == 0 ]] && slot_has older && ! $SUDO test -e "$W/root/run/ga-rauc-floor/allow-older"; then
  ok "older bundle with the operator token → installed, token consumed"
else bad "override through real RAUC: rc=$rc: $(tail -3 "$W/install.out" | tr '\n' ' ')"; fi

# The LIVE templates through the real parser: the rendered iHost system.conf
# (with the [handlers] key) must load, and a bundle built from the rendered
# manifest (with the [meta.ga] group) must verify and report its release.
# shellcheck source=tempio.sh
. "$HERE/tempio.sh"; tempio_fetch "$W"
L="$W/live"; mkdir -p "$L"
ota_compatible=haos-ihost ota_version=16.3.1.9 ota_ga_release=BOSv1.4.0-rc2 BOOTLOADER=uboot BOOT_SPL=true \
  render "$MF_TPL" > "$L/manifest.raucm"
for img in boot.vfat kernel.img rootfs.img spl.img; do head -c 16384 /dev/urandom > "$L/$img"; done
printf '#!/bin/sh\nexit 0\n' > "$L/hook"; chmod +x "$L/hook"
ota_compatible=haos-ihost BOOTLOADER=uboot BOOT_SPL=true render "$SC_TPL" \
  | sed "s|^path=/etc/rauc/keyring.pem|path=$W/ca.pem|" > "$W/live-system.conf"
if "$RAUC" bundle --cert=sign.pem --key=sign.key --keyring=ca.pem "$L" "$W/live.raucb" >"$W/live.out" 2>&1 \
   && "$RAUC" --conf="$W/live-system.conf" info --output-format=shell "$W/live.raucb" >>"$W/live.out" 2>&1 \
   && grep -q '^RAUC_META_GA_RELEASE=.\{0,1\}BOSv1.4.0-rc2' "$W/live.out"; then
  ok "real RAUC loads the live system.conf and reads release BOSv1.4.0-rc2 from a bundle of the live manifest"
else bad "live templates through real RAUC: $(tail -3 "$W/live.out" | tr '\n' ' ')"; fi

echo
echo "=== ${ran} checks: $((ran - fails)) ok, ${fails} failed ==="
(( ran == 8 )) || { echo "FAIL: expected 8 checks, ran ${ran}"; exit 1; }
(( fails == 0 ))
