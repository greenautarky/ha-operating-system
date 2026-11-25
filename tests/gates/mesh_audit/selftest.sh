#!/bin/bash
# mesh_audit/selftest.sh -- ga-mesh-audit counts and drops nothing (see drive.py).
# Needs network + mount namespaces and real nftables; without them it FAILS, it never skips.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for c in nft ip unshare python3 ping; do command -v "$c" >/dev/null || PATH="$PATH:/usr/sbin:/sbin"; command -v "$c" >/dev/null || { echo "FAIL: $c missing"; exit 1; }; done
export PATH
if unshare -rnm true 2>/dev/null; then exec unshare -rnm python3 -I "$HERE/drive.py"; fi
if sudo -n unshare -nm true 2>/dev/null; then exec sudo -n env "PATH=$PATH" unshare -nm python3 -I "$HERE/drive.py"; fi
echo "FAIL: no network namespace available, nothing was checked"; exit 1
