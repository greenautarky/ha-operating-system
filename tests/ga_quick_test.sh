#!/bin/sh
# ga_quick_test.sh - Quick smoke test for GA features on device
# Usage: scp tests/ga_quick_test.sh root@<device>:/tmp/ && ssh root@<device> sh /tmp/ga_quick_test.sh

PASS=0
FAIL=0

check() {
  desc="$1"
  shift
  if eval "$@" >/dev/null 2>&1; then
    echo "  PASS  $desc"
    PASS=$((PASS+1))
  else
    echo "  FAIL  $desc"
    FAIL=$((FAIL+1))
  fi
}

echo "=== GA Quick Test ==="
echo ""

echo "--- Build Info ---"
grep GA_ /etc/os-release 2>/dev/null || echo "(no GA_ fields)"
echo ""

echo "--- Services ---"
check "telegraf running"          systemctl is-active telegraf
check "fluent-bit running"        systemctl is-active fluent-bit
check "crash-marker enabled"      systemctl is-enabled ga-crash-marker
check "boot-check enabled"        systemctl is-enabled ga-boot-check
check "disk-guard timer active"   systemctl is-active ga-disk-guard.timer
echo ""

echo "--- Env Files ---"
check "telegraf env exists"       test -f /mnt/data/telegraf/env
check "fluent-bit env exists"     test -f /mnt/data/fluent-bit/env
check "GA_ENV set"                grep -q "GA_ENV=" /mnt/data/telegraf/env
check "DEVICE_UUID not unknown"   grep -q "DEVICE_UUID=" /mnt/data/telegraf/env '&&' '!' grep -q "DEVICE_UUID=unknown" /mnt/data/telegraf/env
check "GATEWAY_IP not unknown"    grep -q "GATEWAY_IP=" /mnt/data/telegraf/env '&&' '!' grep -q "GATEWAY_IP=unknown" /mnt/data/telegraf/env
echo ""

echo "--- Configs on rootfs ---"
check "telegraf.conf on rootfs"   test -f /etc/telegraf/telegraf.conf
check "fluent-bit.conf on rootfs" test -f /etc/fluent-bit/fluent-bit.conf
echo ""

echo "--- Crash Detection ---"
check "crash marker file exists"  test -f /mnt/data/.ga_unclean_shutdown
check "boot-check ran"            journalctl -u ga-boot-check -b 0 --no-pager -q | grep -qE "Clean boot|UNCLEAN"
echo ""

echo "--- Disk Guard ---"
check "disk guard script exists"  test -x /usr/sbin/ga_disk_guard
check "state file exists"         test -f /run/ga_disk_guard/state.json
echo ""

echo "--- Network ---"
check "default route exists"      ip route | grep -q "^default"
check "ping 1.1.1.1"             ping -c 1 -W 3 1.1.1.1
echo ""

echo "--- Boot Timing ---"
check "boot-timing script exists" test -x /usr/libexec/ga-boot-timing
if [ -x /usr/libexec/ga-boot-timing ]; then
  echo "  Output: $(/usr/libexec/ga-boot-timing 2>/dev/null | head -c 200)"
fi
echo ""

echo "--- RAUC ---"
check "rauc status OK"            rauc status
SLOT=$(rauc status 2>/dev/null | grep "booted" | head -1)
echo "  Booted slot: ${SLOT:-unknown}"
echo ""

echo "--- Journal ---"
check "persistent journal"        test -d /var/log/journal
BOOTS=$(journalctl --list-boots 2>/dev/null | wc -l)
echo "  Boot history: ${BOOTS} boots"
echo ""

echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] && echo "All good!" || echo "Some checks failed - review above"
exit $FAIL
