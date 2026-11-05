#!/bin/sh
# Host-side selftest for checks.sh (no device). Usage: sh selftest.sh [repo-root]
D="$(cd "$(dirname "$0")" && pwd)"; . "$D/checks.sh"
R="${1:-$D/../../..}"; fail=0
t() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2' want '$3')"; fail=1; fi; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
# fixture = the real upstream-style main file + the REAL shipped conf.d file
printf '[device]\nwifi.scan-rand-mac-address=no\n[connectivity]\nuri=http://checkonline.home-assistant.io/online.txt\n' > "$W/main.conf"
G="$R/buildroot-external/rootfs-overlay/etc/NetworkManager/conf.d/50-ga.conf"
t NET-07 "$(nm_effective uri "$W/main.conf" "$G")" "https://checkonline.greenautarky.com/online.txt"
t NET-07-order-matters "$(nm_effective uri "$G" "$W/main.conf")" "http://checkonline.home-assistant.io/online.txt"
t NET-21 "$(nm_effective wifi.cloned-mac-address "$W/main.conf" "$G")" permanent
t NET-22-product "$(nm_effective wifi.scan-rand-mac-address "$W/main.conf" "$G")" no
t missing-key "$(nm_effective nope "$W/main.conf" "$G")" ""
for l in BOSv1.6.0 BOSv1.5.3 ""; do ota_prod_slot_required "$l"; t "slot-required[$l]" $? 0; done
for l in BOSv1.6.0-dev1 BOSv1.6.0-rc2; do ota_prod_slot_required "$l"; t "slot-skipped[$l]" $? 1; done
exit $fail
