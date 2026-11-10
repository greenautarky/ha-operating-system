#!/usr/bin/env bash
# =============================================================================
# selftest.sh — the iHost boot script gives the USB serial gadget a serial number
# =============================================================================
# Odoo #1723. The iHost's g_serial (built-in, CONFIG_USB_G_SERIAL=y) has no
# iSerialNumber unless the kernel command line carries
# g_serial.iSerialNumber=<serial#>. This gate evaluates the LIVE boot script's
# `setenv bootargs_ga` / `if test -n` lines (a tiny evaluator for exactly those
# statements) twice and asserts:
#   serial# set   -> bootargs_ga ends with g_serial.iSerialNumber=<serial#>
#                    and still carries usbcore.authorized_default=0
#   serial# empty -> NO g_serial.iSerialNumber is emitted at all
# plus both slots' bootargs still append ${bootargs_ga}.
# must-flag cases are mutations of the LIVE script (param removed, guard
# removed, wrong parameter name); the extraction FAILS if it finds nothing.
# What it cannot prove: U-Boot's hush parsing, and the device (HW-08e).
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
USH="${USH:-$ROOT/buildroot-ihost/board/sonoff/ihost/uboot-boot.ush}"
[[ -s "$USH" ]] || { echo "FATAL: $USH missing"; exit 1; }
command -v python3 >/dev/null || { echo "FATAL: python3 required"; exit 1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0
bad() { echo "  FAIL  $*"; fails=$((fails + 1)); }
ok()  { echo "  ok    $*"; }

cat > "$W/ev.py" <<'PY'
import re, sys
path, serial = sys.argv[1], sys.argv[2]
env = {"serial#": serial}
def exp(t): return re.sub(r"\$\{([^}]+)\}", lambda m: env.get(m.group(1), ""), t)
stack, seen = [], 0
for ln in open(path).read().splitlines():
    t = ln.strip()
    if t.startswith("#") or not t: continue
    m = re.match(r'if test -n "\$\{([^}]+)\}"; then$', t)
    if m: stack.append(bool(env.get(m.group(1), ""))); continue
    if t == "fi" and stack: stack.pop(); continue
    m = re.match(r'setenv bootargs_ga "(.*)"$', t)
    if m and all(stack):
        env["bootargs_ga"] = exp(m.group(1)); seen += 1
if not seen: sys.exit(3)
print(env["bootargs_ga"])
PY
ga() { python3 "$W/ev.py" "$1" "$2"; }

check() {  # <label> <script> pass|flag
  local label="$1" f="$2" want="$3" set empty good=1
  set=$(ga "$f" "0123456789abcdef") || { bad "$label: extraction found no bootargs_ga (gate would be blind)"; return; }
  empty=$(ga "$f" "") || { bad "$label: extraction (empty) failed"; return; }
  [[ "$set" == *"usbcore.authorized_default=0"* ]] || good=0
  [[ "$set" == *" g_serial.iSerialNumber=0123456789abcdef" ]] || good=0
  [[ "$empty" != *iSerialNumber* ]] || good=0
  if [[ "$want" == pass ]]; then
    [[ $good == 1 ]] && ok "$label" || bad "$label (set='$set' empty='$empty')"
  else
    [[ $good == 0 ]] && ok "$label (flagged, as it must be)" || bad "$label was NOT flagged"
  fi
}

check "live script" "$USH" pass
n=$(grep -c 'rauc.slot=[AB] ${cmdline} ${bootargs_ga}' "$USH")
[[ "$n" == 2 ]] && ok "both boot slots append \${bootargs_ga}" || bad "slot bootargs lines: $n != 2"

sed '/g_serial.iSerialNumber/d' "$USH" > "$W/m1"
check "mutation: param removed" "$W/m1" flag
awk '/^if test -n "\$\{serial#\}"; then$/ {next} /^fi$/ && !d {d=1; next} {print}' "$USH" > "$W/m2"
check "mutation: guard removed" "$W/m2" flag
sed 's/g_serial.iSerialNumber=/g_serial.serial=/' "$USH" > "$W/m3"
check "mutation: wrong parameter name" "$W/m3" flag

# --- acceptance 1 (flasher): ONLY iSerialNumber is added --------------------
# The flasher keys on 0525:a4a7, product "Gadget Serial v2.4", the manufacturer
# string (kernel version) and /dev/ttyGS0. Those come from g_serial's own
# defaults, so they stay unchanged iff nothing overrides them.
only_serial() {  # <file> -> 0 when no g_serial./usb-id override other than iSerialNumber
  ! grep -E 'g_serial\.(idVendor|idProduct|bcdDevice|iManufacturer|iProduct|use_acm|use_obex|n_ports|[A-Za-z_]+)=' "$1" \
      | grep -vE 'g_serial\.iSerialNumber=' | grep -q .
}
BOARD="$ROOT/buildroot-ihost/board/sonoff/ihost"
for f in "$USH" "$BOARD/cmdline.txt" "$BOARD/boot-env.txt"; do
  [[ -e "$f" ]] || { bad "input missing: $f"; continue; }
  only_serial "$f" && ok "$(basename "$f"): no g_serial parameter besides iSerialNumber" || bad "$(basename "$f"): other g_serial parameter present"
done
{ cat "$USH"; echo 'setenv x "g_serial.idProduct=0x1"'; } > "$W/m4"
only_serial "$W/m4" && bad "mutation: idProduct override NOT flagged" || ok "mutation: idProduct override flagged"
if grep -rlE 'gadget/legacy/(serial|g_serial)' "$ROOT/buildroot-ihost" "$ROOT/buildroot-external" 2>/dev/null | grep -q .; then
  bad "a repo patch/config touches drivers/usb/gadget/legacy/serial.c (VID:PID/strings would change)"
else ok "no repo patch touches gadget/legacy/serial.c"; fi
# Constants read from the kernel source when a tree is given (KSRC=<linux dir>);
# CI has none, so the line says so instead of passing silently.
K="${KSRC:-}/drivers/usb/gadget/legacy/serial.c"
if [[ -n "${KSRC:-}" && -r "$K" ]]; then
  grep -q 'GS_VENDOR_ID[[:space:]]*0x0525' "$K" && grep -q 'GS_CDC_PRODUCT_ID[[:space:]]*0xa4a7' "$K" \
    && grep -q '"v2.4"' "$K" && ok "kernel source: 0525:a4a7 (CDC-ACM default), v2.4" || bad "kernel source: VID:PID/version differ from the flasher's 0525:a4a7 / v2.4"
else
  echo "  note  KSRC not set: kernel-source constants NOT checked here (device run: lsusb 0525:a4a7)"
fi

[[ $fails == 0 ]] && { echo "ihost_gadget_serial: PASS"; exit 0; }
echo "ihost_gadget_serial: $fails FAIL"; exit 1
