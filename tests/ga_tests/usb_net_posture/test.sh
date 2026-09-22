#!/bin/sh
# WP7 build self-test — USB host port closed by default + WiFi MAC not
# randomized (ADR-0029 D3/D6). Checks the SHIPPED source files, and proves each
# check goes RED on a mutated copy (rule 45: a check that can only pass is
# uninformative). It reads the LIVE definition — the actual overlay files, never
# a re-declared copy (rule 51b) — so it rots WITH the config it guards.
#
# Runs host-side (build lane): needs only sh + grep. Registered in run_all.sh.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
REPO="$SCRIPT_DIR/../../.."

CMDLINE="$REPO/buildroot-ihost/board/sonoff/ihost/cmdline.txt"
RULE="$REPO/buildroot-ihost/rootfs-overlay/usr/lib/udev/rules.d/80-ga-usb-authorize.rules"
HELPER="$REPO/buildroot-ihost/rootfs-overlay/usr/libexec/ga-usb-authorize"
ALLOW="$REPO/buildroot-ihost/rootfs-overlay/usr/share/ga-usb-allowlist"
NMCONF="$REPO/buildroot-external/rootfs-overlay/etc/NetworkManager/NetworkManager.conf"

suite_start "USB + MAC posture (build)"

# The subject of this suite is the SOURCE TREE, not a running device: every
# check reads an overlay file out of the checkout. Shipped to a device by
# run_device_tests.sh only tests/ travels, so those paths do not exist, every
# check fails for the same reason, and — worse — each RED-proof PASSES
# vacuously, because a mutation of a file that is not there flags just as
# happily as a real one. Measured on K31 on 2026-09-22: six honest failures
# next to four proofs that proved nothing.
#
# So: if the definitions are not readable, this suite FAILS as one finding and
# stops. It never skips (a skipped posture check reads as "fine"), and it never
# runs its own red proofs against absent files.
MISSING=""
for f in "$CMDLINE" "$RULE" "$HELPER" "$ALLOW" "$NMCONF"; do
    [ -r "$f" ] || MISSING="$MISSING $(basename "$f")"
done
if [ -n "$MISSING" ]; then
    run_test "BLD-USB-00" "source tree readable (this is a BUILD-lane suite) — missing:$MISSING — run it from a checkout (run_all.sh emu/all), not over a device" "false"
    suite_end
    exit 1
fi

# The extraction under test, as ONE function each, run against the live file AND
# a mutation. must-pass = the shipped file; must-flag = the mutation.
usb_closed()  { grep -qE 'usbcore\.authorized_default=0' "$1"; }
mac_permanent(){ grep -qE '^\s*wifi\.cloned-mac-address\s*=\s*permanent' "$1"; }
scan_rand_off(){ grep -qE '^\s*wifi\.scan-rand-mac-address\s*=\s*no' "$1"; }
allow_empty() { ! grep -qviE '^[[:space:]]*(#|$)' "$1"; }

# ── must-pass: the shipped files ────────────────────────────────────────────
run_test "BLD-USB-01" "cmdline closes the host data path (usbcore.authorized_default=0)" \
  "usb_closed '$CMDLINE'"
run_test "BLD-USB-02" "udev authorize rule ships and calls the helper" \
  "grep -q 'ga-usb-authorize' '$RULE' && grep -q 'DEVTYPE}==\"usb_device\"' '$RULE'"
run_test "BLD-USB-03" "authorize helper ships + executable" "test -x '$HELPER'"
run_test "BLD-USB-04" "allowlist ships and is EMPTY by default" "test -f '$ALLOW' && allow_empty '$ALLOW'"
run_test "BLD-MAC-01" "NetworkManager pins the permanent WiFi MAC" "mac_permanent '$NMCONF'"
run_test "BLD-MAC-02" "scan-time MAC randomization disabled" "scan_rand_off '$NMCONF'"

# ── must-flag: mutations MUST make the SAME extraction go red (rule 45) ──────
TMP="$(mktemp -d 2>/dev/null || echo /tmp/wp7_$$)"; mkdir -p "$TMP"
# open the host port (drop the cmdline token)
sed 's/ *usbcore\.authorized_default=0//' "$CMDLINE" > "$TMP/cmdline.open"
run_test "BLD-USB-01r" "RED-proof: an OPEN cmdline is flagged" "! usb_closed '$TMP/cmdline.open'"
# a non-empty allowlist is flagged as not-empty
printf '1a86:55d3\n' >> "$TMP/allow.nonempty"
run_test "BLD-USB-04r" "RED-proof: a non-empty allowlist is flagged" "! allow_empty '$TMP/allow.nonempty'"
# randomization turned on
sed 's/wifi\.cloned-mac-address=permanent/wifi.cloned-mac-address=random/' "$NMCONF" > "$TMP/nm.random"
run_test "BLD-MAC-01r" "RED-proof: cloned-mac=random is flagged" "! mac_permanent '$TMP/nm.random'"
sed 's/wifi\.scan-rand-mac-address=no/wifi.scan-rand-mac-address=yes/' "$NMCONF" > "$TMP/nm.scanrand"
run_test "BLD-MAC-02r" "RED-proof: scan-rand=yes is flagged" "! scan_rand_off '$TMP/nm.scanrand'"

# helper fails CLOSED: a device NOT on the allowlist is denied; one ON it is authorized
DENY="$(GA_USB_TEST=1 GA_USB_ALLOWLIST="$ALLOW" sh "$HELPER" /sys/x 1a86 55d3 2>/dev/null)"
run_test "BLD-USB-05" "helper DENIES a device absent from the (empty) allowlist" \
  "echo '$DENY' | grep -q '^deny 1a86:55d3'"
printf '1a86:55d3\n' > "$TMP/allow.one"
ALLOWED="$(GA_USB_TEST=1 GA_USB_ALLOWLIST="$TMP/allow.one" sh "$HELPER" /sys/x 1A86 55D3 2>/dev/null)"
run_test "BLD-USB-06" "helper AUTHORIZES an allowlisted device (case-insensitive)" \
  "echo '$ALLOWED' | grep -q '^authorize 1a86:55d3'"

rm -rf "$TMP"
suite_end
