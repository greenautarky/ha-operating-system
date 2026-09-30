#!/usr/bin/env bash
# =============================================================================
# selftest.sh — the USB host lock reaches a device UPDATED over the air
# =============================================================================
# ADR-0029 D3: the iHost boots with usbcore.authorized_default=0. A fresh flash
# gets it from cmdline.txt. A device that reaches the image by an OTA update
# does not: the RAUC boot-slot hook (buildroot-external/ota/rauc-hook,
# install_boot) copies the bundle's boot partition over /mnt/boot and then puts
# the device's own *.txt files back — so cmdline.txt stays whatever the
# device's FIRST image wrote. boot.scr, on the other hand, is replaced.
#
# This gate starts from that state and follows the real path:
#   1. a /mnt/boot as an older image left it: cmdline.txt WITHOUT the flag;
#   2. the LIVE rauc-hook runs its boot-slot install against the bundle's boot
#      files (the LIVE cmdline.txt and the LIVE uboot-boot.ush as boot.scr);
#   3. the kernel command line U-Boot would build from the result is evaluated
#      from the LIVE boot script's own `setenv` lines, and the LAST
#      usbcore.authorized_default on it (the kernel keeps the last one) must be 0.
#
# Only paths are moved: install_boot's three hard-coded directories are
# rewritten into a temp dir (a substitution that stops matching FAILS the
# gate), and mount/umount/systemctl are stubs — `mount` copies the bundle's
# boot directory, which is what mounting its vfat image exposes.
#
# What it cannot prove — the device run must: that U-Boot's hush parses the
# script (mkimage and a real boot), and /proc/cmdline on an updated canary.
#
# must-flag cases are mutations of the LIVE boot script, so the evaluator is
# shown to go red for the right reason; must-pass is the live script against
# three device cmdlines (flag missing, flag present, flag explicitly opened).
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
HOOK="$ROOT/buildroot-external/ota/rauc-hook"
USH="$ROOT/buildroot-ihost/board/sonoff/ihost/uboot-boot.ush"
CMDLINE="$ROOT/buildroot-ihost/board/sonoff/ihost/cmdline.txt"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
fails=0; ran=0
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }
for f in "$HOOK" "$USH" "$CMDLINE"; do [[ -s "$f" ]] || { echo "FATAL: $f missing"; exit 1; }; done
command -v python3 >/dev/null || { echo "FATAL: python3 required"; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# ── the LIVE hook, paths relocated ───────────────────────────────────────────
relocate() {  # <from> <to> — exactly one assignment must match
  local n; n=$(grep -c "^[[:space:]]*$1$" "$W/hook.sh")
  [[ "$n" == 1 ]] || { echo "FATAL: rauc-hook: expected one line '$1', found $n — the relocation no longer matches the hook"; exit 1; }
  sed -i "s#^\([[:space:]]*\)$1\$#\1$2#" "$W/hook.sh"
}
cp "$HOOK" "$W/hook.sh"
relocate 'BOOT_TMP=/tmp/boot-tmp' "BOOT_TMP=$W/boot-tmp"
relocate 'BOOT_NEW=/tmp/boot-new' "BOOT_NEW=$W/boot-new"
# install_boot's own BOOT_MNT (the first of several functions that set it).
n=$(awk '/^install_boot\(\)/{f=1} f&&/BOOT_MNT=\/mnt\/boot$/{print NR; exit}' "$W/hook.sh")
[[ -n "$n" ]] || { echo "FATAL: rauc-hook: install_boot no longer sets BOOT_MNT=/mnt/boot"; exit 1; }
sed -i "${n}s#BOOT_MNT=/mnt/boot#BOOT_MNT=$W/mnt-boot#" "$W/hook.sh"

mkdir -p "$W/bin"
cat > "$W/bin/mount" <<'EOF'
#!/bin/sh
# stub: "mount <bundle boot image> <dir>" exposes the image's files
cp -a "$1/." "$2/"
EOF
printf '#!/bin/sh\nexit 0\n' > "$W/bin/umount"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/systemctl"
chmod +x "$W/bin/"*

# Kernel command line U-Boot builds for slot <A|B> from <boot.scr> + <cmdline.txt>,
# and the value the kernel keeps for usbcore.authorized_default (the LAST one).
bootargs() {  # <boot.scr> <cmdline.txt> <slot>
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
script, cmdfile, slot = sys.argv[1:4]
env = {}
# fileenv reads the file into ${cmdline}; line breaks become spaces.
env["cmdline"] = " ".join(open(cmdfile).read().split())
target = None
for line in open(script):
    s = line.strip()
    m = re.match(r'^setenv\s+(\w+)\s+"([^"\\]*)"\s*$', s)
    if not m:
        continue
    name, val = m.groups()
    if name == "bootargs" and ("rauc.slot=%s " % slot) in val:
        target = val            # the slot's assembled command line
    elif name != "bootargs":
        env[name] = val
if target is None:
    print("NO-BOOTARGS-LINE"); sys.exit(0)
out = re.sub(r'\$\{(\w+)\}', lambda m: env.get(m.group(1), ""), target)
vals = re.findall(r'(?:^|\s)usbcore\.authorized_default=(\S+)', out)
print("%s|%s" % (vals[-1] if vals else "UNSET", " ".join(out.split())))
PY
}

# ota <name> <device cmdline content> <bundle boot script> -> runs the live hook; echoes the boot dir
ota() {
  local d="$W/$1"; rm -rf "$d" "$W/mnt-boot" "$W/boot-tmp" "$W/boot-new"
  mkdir -p "$d/bundle" "$W/mnt-boot/EFI/BOOT" "$W/mnt-boot/overlays"
  # the device as an older image left it
  printf '%s\n' "$2" > "$W/mnt-boot/cmdline.txt"
  printf 'OLD BOOT SCRIPT\n' > "$W/mnt-boot/boot.scr"
  cp "$ROOT/buildroot-ihost/board/sonoff/ihost/boot-env.txt" "$W/mnt-boot/haos-config.txt"
  # the bundle's boot image: what hassos-hook.sh puts there
  cp "$CMDLINE" "$d/bundle/cmdline.txt"
  cp "$3" "$d/bundle/boot.scr"
  cp "$ROOT/buildroot-ihost/board/sonoff/ihost/boot-env.txt" "$d/bundle/haos-config.txt"
  if ! PATH="$W/bin:$PATH" RAUC_SLOT_CLASS=boot RAUC_SYSTEM_COMPATIBLE=haos-ihost \
       RAUC_IMAGE_NAME="$d/bundle" sh "$W/hook.sh" slot-install >"$d/hook.out" 2>&1; then
    echo "FATAL: rauc-hook slot-install failed: $(tail -3 "$d/hook.out")" >&2; return 1
  fi
  rm -rf "${d:?}/boot"; cp -a "$W/mnt-boot" "$d/boot"
  printf '%s' "$d/boot"
}

# The pre-lock iHost command line: the live one without the flag.
OLD_CMD="$(sed -E 's/[[:space:]]*usbcore\.authorized_default=[^[:space:]]*//g' "$CMDLINE" | head -1)"
[[ -n "$OLD_CMD" && "$OLD_CMD" != *authorized_default* ]] || { echo "FATAL: could not derive a pre-lock cmdline"; exit 1; }

expect() {  # <want 0|open> <boot-dir> <boot.scr> <desc>
  local slot r v
  for slot in A B; do
    ran=$((ran+1)); r="$(bootargs "$3" "$2/cmdline.txt" "$slot")"; v="${r%%|*}"
    if [[ "$1" == 0 ]]; then
      [[ "$v" == 0 ]] && ok "slot $slot: host port closed — $4" || bad "slot $slot: usbcore.authorized_default=$v — $4  [${r#*|}]"
    else
      [[ "$v" != 0 ]] && ok "slot $slot: flagged as open ($v) — $4" || bad "slot $slot: mutation NOT flagged — $4"
    fi
  done
}

echo "── the update path itself (live rauc-hook) ──"
B="$(ota flagless "$OLD_CMD" "$USH")" || exit 1
ran=$((ran+1)); cmp -s "$B/boot.scr" "$USH" && ok "boot.scr is replaced by the bundle's" || bad "boot.scr was not replaced by the bundle's"
ran=$((ran+1)); [[ "$(head -1 "$B/cmdline.txt")" == "$OLD_CMD" ]] && ok "cmdline.txt is the DEVICE's (restored, no flag) — the state this gate exists for" || bad "cmdline.txt is not the device's copy after the update: $(head -1 "$B/cmdline.txt")"

echo "── must-pass: the live boot script closes the port after an update ──"
expect 0 "$B" "$B/boot.scr" "device cmdline.txt from a pre-lock image (no flag)"
B2="$(ota flagged "$(head -1 "$CMDLINE")" "$USH")" || exit 1
expect 0 "$B2" "$B2/boot.scr" "device cmdline.txt already carrying the flag"
B3="$(ota opened "$OLD_CMD usbcore.authorized_default=1" "$USH")" || exit 1
expect 0 "$B3" "$B3/boot.scr" "device cmdline.txt that sets usbcore.authorized_default=1"

echo "── must-flag: mutations of the live boot script ──"
sed 's/ \${bootargs_ga}"/"/' "$USH" > "$W/ush.dropped"
cmp -s "$USH" "$W/ush.dropped" && { echo "FATAL: mutation 1 changed nothing — the live script no longer has the expected shape"; exit 1; }
B4="$(ota m-dropped "$OLD_CMD" "$W/ush.dropped")" || exit 1
expect open "$B4" "$B4/boot.scr" "script without the appended flag (the flag only in cmdline.txt)"
sed 's/ \${cmdline} \${bootargs_ga}"/ ${bootargs_ga} ${cmdline}"/' "$USH" > "$W/ush.before"
cmp -s "$USH" "$W/ush.before" && { echo "FATAL: mutation 2 changed nothing"; exit 1; }
B5="$(ota m-before "$OLD_CMD usbcore.authorized_default=1" "$W/ush.before")" || exit 1
expect open "$B5" "$B5/boot.scr" "flag placed BEFORE \${cmdline}, device cmdline opens the port (last value wins)"

echo
if (( ran < 12 )); then echo "${RED}FAIL${NC}  only $ran cases ran — expected at least 12"; exit 1; fi
if (( fails > 0 )); then echo "${RED}${fails} of ${ran} case(s) failed${NC}"; exit 1; fi
echo "${GRN}all ${ran} cases passed${NC}"
