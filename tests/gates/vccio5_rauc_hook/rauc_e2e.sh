#!/usr/bin/env bash
# =============================================================================
# rauc_e2e.sh — a REAL RAUC runs the LIVE vccio5 install-check hook (Odoo #1981)
# =============================================================================
# selftest.sh calls the hook directly. This proves the seam with RAUC itself:
#   * RAUC runs the bundle's install-check hook (the hook ships IN the bundle —
#     the system.conf here has no handlers, so nothing else can write the key)
#   * a refusal (cmdline vs PMUGRF mismatch, unreadable PMUGRF) aborts the
#     install with "Install-check hook failed" and the target slot stays
#     untouched — the key decision happens before any slot is written
#   * an accepted install writes the slot AND the pinned key
#   * a present key is left alone
# Sandbox: throwaway CA + signing key, two raw slot FILES, bootloader=noop,
# `rauc service` on a private D-Bus session bus, compatible haos-ihost. The hook
# is the LIVE patched file (scripts/apply-haos-patches.sh --cat). It runs in the
# SERVICE's environment, so the scratch paths (GA_VCC_*) and the fake systemctl
# and grub-editenv are given to the service, not to the client.
#
# RAUC 1.11.3 (CI) prints Hook returned: <msg>, 1.13 (devices) Hook returned: '<msg>' — the
# match allows both.
# Needs root (loop + dm-verity mounts): run as root or with passwordless sudo.
#   RAUC=<path to rauc> ./rauc_e2e.sh      (default: rauc on PATH)
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RAUC="${RAUC:-$(command -v rauc || true)}"
fails=0; ran=0
ok()  { ran=$((ran+1)); echo "  ok    $*"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); echo "  FAIL  $*"; }

[[ -n "$RAUC" && -x "$RAUC" ]] || { echo "FATAL: no rauc binary (set RAUC=)"; exit 1; }
SUDO=""; [[ "$(id -u)" == 0 ]] || SUDO="sudo -n"
$SUDO true 2>/dev/null || { echo "FATAL: needs root or passwordless sudo"; exit 1; }
command -v dbus-run-session >/dev/null || { echo "FATAL: dbus-run-session missing"; exit 1; }
echo "=== vccio5 install-check hook through a real RAUC: $("$RAUC" --version) ==="

W="$(mktemp -d)"; trap '$SUDO rm -rf "$W"' EXIT
bash "$ROOT/scripts/apply-haos-patches.sh" --cat buildroot-external/ota/rauc-hook > "$W/hook" 2>/dev/null \
  || { echo "FATAL: cannot extract the patched rauc-hook"; exit 1; }
grep -q 'ga_vccio5_pin()' "$W/hook" || { echo "FATAL: the patched rauc-hook has no ga_vccio5_pin"; exit 1; }
chmod +x "$W/hook"
cd "$W" || exit 1
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 \
  -subj "/CN=vcc-e2e-ca" -addext basicConstraints=critical,CA:TRUE >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout sign.key -out sign.csr -subj "/CN=vcc-e2e-sign" >/dev/null 2>&1
openssl x509 -req -in sign.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out sign.pem -days 2 >/dev/null 2>&1
[[ -s sign.pem ]] || { echo "FATAL: could not mint throwaway certificates"; exit 1; }

# one bundle: the live hook as install-check + one raw rootfs image with a marker
mkdir -p c
printf '[update]\ncompatible=haos-ihost\nversion=18.4.1.99\n\n[bundle]\nformat=verity\n\n[hooks]\nfilename=hook\nhooks=install-check;\n\n[image.rootfs]\nfilename=rootfs.img\n' > c/manifest.raucm
cp hook c/hook
{ printf 'PAYLOAD-VCC\n'; head -c 65536 /dev/urandom; } > c/rootfs.img
"$RAUC" bundle --cert=sign.pem --key=sign.key --keyring=ca.pem c "$W/b.raucb" >/dev/null 2>&1 \
  || { echo "FATAL: rauc bundle failed"; exit 1; }

mkdir -p mnt bin boot
printf '#!/bin/sh\nexit 0\n' > bin/systemctl; cp bin/systemctl bin/grub-editenv; chmod +x bin/systemctl bin/grub-editenv
cat > system.conf <<EOF
[system]
compatible=haos-ihost
bootloader=noop
mountprefix=$W/mnt
statusfile=$W/rauc.db

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

cat > run-install.sh <<'EOS'
#!/bin/sh
# $1 rauc  $2 workdir — the service gets the scratch paths and fakes, the client nothing
export DBUS_STARTER_BUS_TYPE=session
env PATH="$2/bin:$PATH" GA_VCC_BOOT="$2/boot" GA_VCC_CMDLINE="$2/cmdline" GA_VCC_REGMAP="$2/regmap" \
  "$1" service --conf="$2/system.conf" --override-boot-slot=A >"$2/service.log" 2>&1 &
svc=$!
i=0; until "$1" status >/dev/null 2>&1 || [ $i -ge 20 ]; do i=$((i+1)); sleep 0.5; done
"$1" install "$2/b.raucb"; rc=$?
kill $svc 2>/dev/null; wait $svc 2>/dev/null
exit $rc
EOS

# scenario <cfg|-ABSENT-> <cmdline> <regmap|-ABSENT-> -> RC; CFG after; slot written?
scenario() {
  $SUDO rm -f boot/haos-config.txt regmap rauc.db
  truncate -s 0 slotA.img slotB.img; truncate -s 128K slotA.img slotB.img
  [[ "$1" == -ABSENT- ]] || printf '%b' "$1" > boot/haos-config.txt
  printf '%s\n' "$2" > cmdline
  [[ "$3" == -ABSENT- ]] || printf '%s\n' "$3" > regmap
  BEFORE="$(cat boot/haos-config.txt 2>/dev/null || echo -ABSENT-)"
  $SUDO dbus-run-session -- sh "$W/run-install.sh" "$RAUC" "$W" > "$W/install.out" 2>&1; RC=$?
  CFG="$($SUDO cat boot/haos-config.txt 2>/dev/null || echo -ABSENT-)"
  if grep -aq 'PAYLOAD-VCC' slotB.img; then SLOT=written; else SLOT=untouched; fi
  LOG="$(cat "$W/install.out" "$W/service.log" 2>/dev/null)"
}

scenario "overlays=x\n" "root=x rootwait" "140: 000000a6"
[[ $RC == 0 && $SLOT == written && "$CFG" == $'overlays=x\nga_vccio5=1v8' ]] \
  && ok "keyless 1.8 V field unit (no ga.vccio5 argument): installed, slot written, ga_vccio5=1v8 pinned" \
  || bad "keyless field unit: rc=$RC slot=$SLOT cfg=$(tr '\n' '|' <<<"$CFG") :: $(tail -3 <<<"$LOG" | tr '\n' ' ')"

scenario "" "root=x ga.vccio5=3v3 rootwait" "140: 00000086"
[[ $RC == 0 && $SLOT == written && "$CFG" == "ga_vccio5=3v3" ]] \
  && ok "keyless new unit running 3v3: installed, ga_vccio5=3v3 pinned (not downgraded)" \
  || bad "keyless 3v3 unit: rc=$RC slot=$SLOT cfg=$(tr '\n' '|' <<<"$CFG") :: $(tail -3 <<<"$LOG" | tr '\n' ' ')"

scenario "" "root=x ga.vccio5=3v3 rootwait" "140: 000000a6"
[[ $RC != 0 && $SLOT == untouched && "$CFG" == "$BEFORE" && "$LOG" == *"Bundle rejected: Hook returned: "*"GA vccio5:"*"says 1v8"* ]] \
  && ok "cmdline 3v3 vs PMUGRF 1.8 V: RAUC rejects WITH the reason, slot untouched, key untouched" \
  || bad "mismatch: rc=$RC slot=$SLOT cfg=$(tr '\n' '|' <<<"$CFG") :: $(grep -iE 'hook|GA vccio5' <<<"$LOG" | tail -3 | tr '\n' ' ')"

scenario "overlays=x\n" "root=x rootwait" -ABSENT-
[[ $RC != 0 && $SLOT == untouched && "$CFG" == "$BEFORE" && "$LOG" == *"Bundle rejected: Hook returned: "*"GA vccio5: cannot read PMUGRF"* ]] \
  && ok "PMUGRF unreadable: RAUC rejects WITH the reason, slot untouched, nothing written" \
  || bad "unreadable PMUGRF: rc=$RC slot=$SLOT :: $(grep -iE 'hook|GA vccio5' <<<"$LOG" | tail -3 | tr '\n' ' ')"

scenario "ga_vccio5=1v8\n" "root=x ga.vccio5=3v3" "140: 00000086"
[[ $RC == 0 && $SLOT == written && "$CFG" == "ga_vccio5=1v8" ]] \
  && ok "key present (1v8): installed, key left as it is" \
  || bad "key present: rc=$RC slot=$SLOT cfg=$(tr '\n' '|' <<<"$CFG")"

echo "vccio5 rauc e2e: $((ran - fails))/$ran ok"
[[ $fails -eq 0 && $ran -eq 5 ]]
