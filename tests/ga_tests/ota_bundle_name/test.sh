#!/bin/sh
# ota_bundle_name — ga-rauc-install requests the bundle name the BAKE produces
# for the board it runs on (haos_<BOARD_ID>-<ver>.raucb; ga_build.sh renames
# the prefix only, so the board stays in the name).
#   producer: board meta BOARD_ID   consumer: URL ga-rauc-install builds
# Expected names are pinned constants (rule 7), not read from the script.
# Real script, only curl stubbed (records the URL, always fails -> exit 3).
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
D="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$ROOT/buildroot-external/rootfs-overlay/usr/sbin/ga-rauc-install"
W="$(mktemp -d)" || { echo "ERROR (could not check): mktemp failed" >&2; exit 2; }; mkdir -p "$W/bin" || exit 2; trap 'rm -rf "$W"' EXIT
printf '#!/bin/sh\nfor a; do case "$a" in https://*) echo "$a" >> "%s/urls";; esac; done\nexit 22\n' "$W" > "$W/bin/curl"; chmod +x "$W/bin/curl"
printf '%s\n' "$(printf '100.%d.0.9' 100)" > "$W/active"
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1 (want '$3' got '$2')"; fail=$((fail+1)); fi; }
run() { : > "$W/urls"; PATH="$W/bin:$PATH" GA_OS_RELEASE="$1" GA_OTA_ACTIVE_FILE="$W/active" GA_STAGING_DIR="$W/stg" \
        sh "$SCRIPT" 18.4.1.6 ${2:-} >"$W/out" 2>&1; }
# producer facts (pinned): bundle basenames per board
for b in ihost dsgw210; do
  grep -q "^BOARD_ID=$b\$" "$(ls "$ROOT"/buildroot-*/board/*/*/meta | grep "/$b/meta\$")" 2>/dev/null \
    && echo "  PASS  producer: a board meta declares BOARD_ID=$b" && pass=$((pass+1)) \
    || { echo "  FAIL  producer: no board meta with BOARD_ID=$b"; fail=$((fail+1)); }
done
run "$D/fixtures/os-release.dsgw210" BOSv1.6.0-rc1
chk "OBN-01 dsgw210 per-rc URL" "$(head -n 1 "$W/urls")" "https://ota.greenautarky.com/releases/18.4.1.6/BOSv1.6.0-rc1/haos_dsgw210-18.4.1.6.raucb"
chk "OBN-02 dsgw210 prod fallback URL" "$(sed -n 2p "$W/urls")" "https://ota.greenautarky.com/releases/18.4.1.6/haos_dsgw210-18.4.1.6.raucb"
run "$D/fixtures/os-release.dsgw210"
chk "OBN-03 dsgw210 prod URL" "$(head -n 1 "$W/urls")" "https://ota.greenautarky.com/releases/18.4.1.6/haos_dsgw210-18.4.1.6.raucb"
run "$D/fixtures/os-release.ihost" BOSv1.6.0-rc1
chk "OBN-04 ihost per-rc URL unchanged" "$(head -n 1 "$W/urls")" "https://ota.greenautarky.com/releases/18.4.1.6/BOSv1.6.0-rc1/haos_ihost-18.4.1.6.raucb"
run "$D/fixtures/os-release.novariant"
chk "OBN-05 no VARIANT_ID: falls back to ihost" "$(head -n 1 "$W/urls")" "https://ota.greenautarky.com/releases/18.4.1.6/haos_ihost-18.4.1.6.raucb"
chk "OBN-06 ... and says so loudly (WARNING)" "$(grep -c 'WARNING: no usable VARIANT_ID' "$W/out")" "1"
echo "ota_bundle_name: $pass passed, $fail failed"; [ "$fail" -eq 0 ] && [ "$pass" -ge 8 ]
